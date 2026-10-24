local journal=require("journal")
local M={}
function M.page(ui)
    local page=ui.newPage("Log",1)
    local card=ui.card(page.left,"Aktionsprotokoll","Letzte 200 Meldungen dieser Sitzung")
    local offset,revision=0,-1
    local text=ui.paragraph("")
    ui.buttonGrid(card,3,{
        {"Neueste",function() offset=0;revision=-1 end},
        {"Aeltere",function() offset=math.min(180,offset+20);revision=-1 end},
        {"Leeren",function() journal.clear();offset=0;revision=-1 end},
    })
    ui.add(card,text)
    ui.addRefresher(page,function()
        if revision==journal.revision() then return end
        revision=journal.revision()
        local rows=journal.lines(20,offset)
        ui.setText(text,#rows>0 and table.concat(rows,"\n\n") or "Keine Meldungen.")
    end)
    return page
end
return M
