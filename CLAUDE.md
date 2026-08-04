# CLAUDE.md - Project Instructions

- Do NOT use the WebSearch tool. It is unreliable. If web data is needed, use WebFetch with a direct API/data URL (e.g., wttr.in).
- Do NOT use the WebFetch tool to fetch general web pages or weather. Only use it for direct API calls when explicitly necessary.

# project design
- read the C:\git\cc\pretoolhook\CLAUDE.md to get the project overall design.

# Testing
- Do NOT rely on the live config.json under the project root dir.  live version of config.json is for normal use.
- Always create (mockup/and modify) config.json file under the same dir that test case file sits, and use that config file.