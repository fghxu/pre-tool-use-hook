# =============================================================================
# Mock-LlmServer.ps1 - reusable local mock LLM endpoint for tests
# =============================================================================
#
# WHAT THIS IS
#   A tiny OpenAI-compatible HTTP endpoint running on 127.0.0.1 inside THIS
#   process (a background runspace + System.Net.HttpListener). Tests point the
#   llm_second_opinion base_uri at it, so the REAL Invoke-RestMethod code path
#   in Get-LlmReviewVerdict runs over a REAL socket - with zero quota, zero
#   external dependency, and full determinism.
#
# WHAT IT PROVES
#   The server RECORDS every request (method, path, Content-Type,
#   Authorization header, raw body). The runner asserts against those
#   captures - most importantly, that a request ARRIVED AT ALL (that is how we
#   know the hook really calls the LLM).
#
# USAGE
#   . .\Mock-LlmServer.ps1
#   $srv = New-MockLlmServer            # picks a free port, starts listening
#   $srv.BaseUri                        # "http://127.0.0.1:<port>"
#   $srv.State.Body   = '<json>'        # program the NEXT response body
#   $srv.State.Status = 200             # program the NEXT response status
#   $srv.State.DelayMs = 0              # program an artificial response delay
#   ... make the HTTP call under test ...
#   $srv.State.RequestCount             # how many requests arrived
#   $srv.State.LastBody / LastMethod / LastPath / LastContentType / LastAuth
#   Stop-MockLlmServer $srv             # always stop at the end
#
# IMPLEMENTATION NOTES
#   - The listener loop runs in a background runspace; $srv.State is a
#     synchronized hashtable shared with it (thread-safe by construction).
#   - Works on both Windows PowerShell 5.1 and pwsh 7+.
# =============================================================================

function New-MockLlmServer {
    <#
    .SYNOPSIS
        Starts a mock LLM HTTP endpoint on a free 127.0.0.1 port and returns a
        handle object. The server answers ONE request at a time (tests are
        sequential, so this is not a limitation) using the response currently
        programmed in State.Body / State.Status / State.DelayMs.
    #>
    param()

    # --- Pick a free port: bind port 0 (OS assigns), read the port, release. ---
    $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $port = $tcp.LocalEndpoint.Port
    $tcp.Stop()

    # --- Shared state (synchronized hashtable = thread-safe). ---
    # Response programming:  Body / Status / DelayMs (read per request)
    # Request capture:       RequestCount / LastMethod / LastPath /
    #                        LastContentType / LastAuth / LastBody
    # Lifecycle:             Stop (set to $true to end the loop)
    $state = [hashtable]::Synchronized(@{
        Stop             = $false
        Body             = '{"choices":[{"message":{"content":"true"}}]}'
        Status           = 200
        DelayMs          = 0
        RequestCount     = 0
        LastMethod       = ''
        LastPath         = ''
        LastContentType  = ''
        LastAuth         = $null
        LastBody         = ''
    })

    # --- Background runspace hosting the listener loop. ---
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param([int]$Port, [hashtable]$State)

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()

        while (-not $State.Stop) {
            # Block until a request arrives (or the listener dies).
            $ctx = $null
            try { $ctx = $listener.GetContext() } catch { break }

            # A dead client (e.g. the timeout test) must not kill the loop,
            # so the whole per-request handling is wrapped.
            try {
                $req = $ctx.Request

                # Read the raw request body (the JSON the hook POSTed).
                $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                $bodyText = $reader.ReadToEnd()

                # Record what arrived for later assertions.
                $State.RequestCount++
                $State.LastMethod       = $req.HttpMethod
                $State.LastPath         = $req.Url.AbsolutePath
                $State.LastContentType  = $req.ContentType
                $State.LastAuth         = $req.Headers['Authorization']
                $State.LastBody         = $bodyText

                # Optional artificial delay (drives the client-timeout test).
                if ($State.DelayMs -gt 0) { Start-Sleep -Milliseconds $State.DelayMs }

                # Send the programmed response.
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($State.Body)
                $ctx.Response.StatusCode = [int]$State.Status
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.OutputStream.Close()
            }
            catch { }
        }
        $listener.Close()
    }).AddArgument($port).AddArgument($state) | Out-Null

    $handle = $ps.BeginInvoke()

    # --- Wait until the listener is actually accepting (max ~3s). ---
    # A bare TCP connect+disconnect does NOT produce an HTTP request, so it
    # does not pollute RequestCount.
    $up = $false
    for ($i = 0; $i -lt 30 -and -not $up; $i++) {
        try {
            $probe = [System.Net.Sockets.TcpClient]::new()
            $probe.Connect('127.0.0.1', $port)
            $probe.Close()
            $up = $true
        }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $up) {
        $runspace.Close()
        throw "New-MockLlmServer: listener failed to start on port $port"
    }

    return [PSCustomObject]@{
        Port     = $port
        BaseUri  = "http://127.0.0.1:$port"
        State    = $state
        PS       = $ps
        Runspace = $runspace
        Handle   = $handle
    }
}

function Stop-MockLlmServer {
    <#
    .SYNOPSIS
        Stops the mock server: signals the loop, pokes it with one dummy
        request so GetContext() unblocks, then tears down the runspace.
    #>
    param([Parameter(Mandatory = $true)]$Server)

    $Server.State.Stop = $true
    try {
        # Unblock GetContext() so the loop can observe Stop and exit.
        $null = Invoke-WebRequest -Uri "$($Server.BaseUri)/" -Method Post `
            -Body '{}' -ContentType 'application/json' -TimeoutSec 2 -UseBasicParsing `
            -ErrorAction SilentlyContinue
    }
    catch { }
    Start-Sleep -Milliseconds 200
    try { $Server.PS.Dispose() } catch { }
    try { $Server.Runspace.Close() } catch { }
    try { $Server.Runspace.Dispose() } catch { }
}
