-- Warden-owned text only. No game culture changes, IO, engine calls or polling.
-- Select before loading feature modules; a language change takes effect on restart.
local english=require("locales.en")
local M={}
local language="de"
function M.normalize(value)
    local code=tostring(value or "de"):lower():match("^%s*(.-)%s*$")
    if code=="en" or code:match("^en[-_]") then return "en" end
    if code=="de" or code:match("^de[-_]") then return "de" end
    return "de"
end
function M.setLanguage(value) language=M.normalize(value);return language end
function M.getLanguage() return language end
function M.t(text)
    if language=="en" then return english[text] or text end
    return text
end
return M
