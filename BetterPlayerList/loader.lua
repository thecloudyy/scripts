-- BetterPlayerList / loader.lua
-- Robust loader: tries every common HttpGet variant so
-- "attempt to call a nil value" on game:HttpGet goes away.

local URL = "https://raw.githubusercontent.com/thecloudyy/scripts/main/BetterPlayerList/src.lua"

-- optional styling (safe even when getgenv is missing)
pcall(function()
	local g = getgenv()
	g.SELFNAME_COLOR = g.SELFNAME_COLOR or Color3.fromRGB(255, 92, 92)
	g.BACKGROUND_IMG = g.BACKGROUND_IMG or "rbxassetid://125749318579873"
	g.SELF_FONT = g.SELF_FONT or Font.new("rbxassetid://12187366846", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
	g.SELF_IMAGEPLATE = g.SELF_IMAGEPLATE or "rbxassetid://89567791746513"
end)

local function fetch(url: string): string
	-- 1. game:HttpGet / game:HttpGetAsync (most executors + Studio)
	local ok, res = pcall(function()
		return (game :: any):HttpGet(url)
	end)
	if ok and typeof(res) == "string" and #res > 0 then
		return res
	end
	ok, res = pcall(function()
		return (game :: any):HttpGetAsync(url)
	end)
	if ok and typeof(res) == "string" and #res > 0 then
		return res
	end
	-- 2. executor request functions
	local req = (rawget(_G, "request") or rawget(_G, "http_request") or rawget(_G, "syn_request")) :: any
	if typeof(req) ~= "function" then
		pcall(function()
			req = (getgenv() :: any).request or (getgenv() :: any).http_request
		end)
	end
	if typeof(req) == "function" then
		local rOk, rRes = pcall(req, { Url = url, Method = "GET" })
		if rOk and rRes then
			if typeof(rRes) == "string" and #rRes > 0 then
				return rRes
			end
			if typeof(rRes) == "table" and typeof((rRes :: any).Body) == "string" then
				return (rRes :: any).Body
			end
		end
	end
	error("BetterPlayerList: no working HTTP fetch (HttpGet/HttpGetAsync/request all failed). Try a different executor.")
	return ""
end

local src = fetch(URL)
local fn, err = loadstring(src)
if not fn then
	error("BetterPlayerList: loadstring failed: " .. tostring(err))
end
return fn()
