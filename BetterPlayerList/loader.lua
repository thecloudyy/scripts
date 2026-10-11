-- BetterPlayerList / loader.lua (single loadstring entrypoint)
-- Configuration: set any of these BEFORE loading to override the defaults.
local _g = getgenv and getgenv() or _G
-- -- Color of your own name in the player list.
_g.SELFNAME_COLOR = _g.SELFNAME_COLOR or Color3.fromRGB(255, 92, 92)
-- -- Header background image (300x65 px). Set to "" to disable.
_g.BACKGROUND_IMG = _g.BACKGROUND_IMG or "rbxassetid://125749318579873"
-- -- Font used for your own name.
_g.SELF_FONT = _g.SELF_FONT or Font.new("rbxassetid://12187366846", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
-- -- Overlay image behind your own entry. Set to "" to disable.
_g.SELF_IMAGEPLATE = _g.SELF_IMAGEPLATE or "rbxassetid://89567791746513"

local URL = "https://raw.githubusercontent.com/thecloudyy/scripts/main/BetterPlayerList/src.lua"
local src
local ok, res = pcall(function() return game:HttpGet(URL) end)
if ok and type(res) == "string" and #res > 0 then src = res end
if not src then
	local ok2, res2 = pcall(function() return game:HttpGetAsync(URL) end)
	if ok2 and type(res2) == "string" and #res2 > 0 then src = res2 end
end
if not src then
	local req = rawget(_G, "request") or rawget(_G, "http_request") or rawget(_G, "syn_request")
	if type(req) == "function" then
		local rOk, rRes = pcall(req, { Url = URL, Method = "GET" })
		if rOk and rRes then
			if type(rRes) == "string" and #rRes > 0 then
				src = rRes
			elseif type(rRes) == "table" and type(rRes.Body) == "string" then
				src = rRes.Body
			end
		end
	end
end
assert(src and #src > 100, "BetterPlayerList: fetch failed")
local loader = loadstring or load
assert(loader, "BetterPlayerList: no loadstring/load in this executor")
local fn, err = loader(src)
assert(fn, "BetterPlayerList: compile failed: " .. tostring(err))
return fn()
