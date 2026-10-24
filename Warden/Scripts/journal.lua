-- Bounded session journal. No disk polling, world scans or per-frame callbacks.
local M={}
local capacity,entries,sequence=200,{},0
function M.add(message,level)
    sequence=sequence+1
    local s=tostring(message):gsub("[\r\n]+"," "):sub(1,600)
    entries[(sequence-1)%capacity+1]={id=sequence,time=os.date("%H:%M:%S"),level=level or "Info",text=s}
end
function M.revision() return sequence end
function M.clear() entries={};sequence=sequence+1 end
function M.lines(count,offset)
    local result={}
    local top=sequence-(offset or 0)
    for id=top,math.max(1,top-(count or 20)+1,sequence-capacity+1),-1 do
        local row=entries[(id-1)%capacity+1]
        if row and row.id==id then
            result[#result+1]=row.time.." ["..row.level.."] "..row.text
        end
    end
    return result
end
return M
