-- Warden-owned text. The game-thread caller reads, but never changes, game culture.
local english=require("locales.en")
local M={}
local language="en"
local reverse,uppercase={},{}
for source,target in pairs(english) do
    reverse[target]=source
    reverse[target:upper()]=source:upper()
    uppercase[source:upper()]=target:upper()
end
function M.normalize(value)
    local code=tostring(value or "en"):lower():match("^%s*(.-)%s*$")
    if code=="en" or code:match("^en[-_]") then return "en" end
    if code=="de" or code:match("^de[-_]") then return "de" end
    return "en"
end
function M.setLanguage(value) language=M.normalize(value);return language end
function M.getLanguage() return language end
function M.sync()
    local ok,code=pcall(function()
        local lib=StaticFindObject('/Script/Engine.Default__KismetInternationalizationLibrary')
        if not lib or not lib:IsValid() then return end
        local value=lib:GetCurrentLanguage()
        return type(value)=='string' and value or value:ToString()
    end)
    if not ok or type(code)~='string' or #code>20 or
        not (code:match('^%a%a%a?$') or code:match('^%a%a%a?[-_][%w%-_]+$')) then return false end
    local nextLanguage=M.normalize(code)
    if nextLanguage==language then return false end
    language=nextLanguage
    return true
end
function M.t(text)
    local source=reverse[text] or text
    if language=="en" then return english[source] or uppercase[source] or text end
    return source
end
return M
