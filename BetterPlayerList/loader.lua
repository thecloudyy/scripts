-- BetterPlayerList / loader.lua

local URL = "https://raw.githubusercontent.com/thecloudyy/scripts/main/BetterPlayerList/src.lua"

pcall(function()
	local g = getgenv()
	g.SELFNAME_COLOR = g.SELFNAME_COLOR or Color3.fromRGB(255, 92, 92)
	g.BACKGROUND_IMG = g.BACKGROUND_IMG or "rbxassetid://125749318579873"
	g.SELF_FONT = g.SELF_FONT or Font.new("rbxassetid://12187366846", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
	g.SELF_IMAGEPLATE = g.SELF_IMAGEPLATE or "rbxassetid://89567791746513"
end)

local function fetch(url)
	local ok, res = pcall(function()
		return game:HttpGet(url)
	end)
	if ok and type(res) == "string" and #res > 0 then
		return res
	end
	ok, res = pcall(function()
		return game:HttpGetAsync(url)
	end)
	if ok and type(res) == "string" and #res > 0 then
		return res
	end
	local req = rawget(_G, "request") or rawget(_G, "http_request") or rawget(_G, "syn_request")
	if type(req) ~= "function" then
		pcall(function()
			local g = getgenv()
			req = g.request or g.http_request
		end)
	end
	if type(req) == "function" then
		local rOk, rRes = pcall(req, { Url = url, Method = "GET" })
		if rOk and rRes then
			if type(rRes) == "string" and #rRes > 0 then
				return rRes
			end
			if type(rRes) == "table" and type(rRes.Body) == "string" then
				return rRes.Body
			end
		end
	end
	error("BetterPlayerList: no working HTTP fetch.")
	return ""
end

local src = fetch(URL)
local fn, err = loadstring(src)
if not fn then
	error("BetterPlayerList: loadstring failed: " .. tostring(err))
end
return fn()
