-- Strongbox v1.0.0 by Kronic: an inventory organizer for Shroud of the Avatar.
-- Add-ons can't list what's inside a bag, chest or bank. They can ask how many of an item you own and
-- where (ShroudSearchOwnedItems, Lua API 55+), by its exact name, one search at a time. So Strongbox
-- builds a list of item names (your recipes, your bag, what you pick up, your Crafters Ledger list and
-- names you add), looks each one up in the background, and saves what it finds.
Strongbox = {}
local S = Strongbox
local VERSION = '1.0.0'
local function say(s) print('[Strongbox] '..s) end
local LUA = type(ShroudLuaPath)=='string' and ShroudLuaPath or nil
local DATA = LUA and (LUA..'/Strongbox-data.tsv') or nil
local CL_DATA = LUA and (LUA..'/CraftersLedger-data.tsv') or nil

local function valid(s) return type(s)=='string' and #s>0 and not s:find('[\t\r\n]') end
local function trim(s) return (tostring(s or ''):gsub('^%s+',''):gsub('%s+$','')) end
local function field(o,k)
    local ok,v=pcall(function() return o[k] end)
    if ok then return v end
end
local function list(v) return type(v)=='table' and v or {} end
local function clock()
    if type(os)=='table' and type(os.clock)=='function' then
        local ok,v=pcall(os.clock); if ok and type(v)=='number' then return v end
    end
end
local function wallTime()
    if type(os)=='table' and type(os.time)=='function' then
        local ok,v=pcall(os.time); if ok and type(v)=='number' then return v end
    end
end

---------------------------------------------------------------------------------------------------
-- What Strongbox knows
local names = {}        -- lower name -> display name: every item name it can look up
local found = {}        -- lower name -> {name,at,total,rows,none,failed,why}; at = wall time (or nil)
local itemType = {}     -- lower name -> type from your bag (weapon, food, reagent...) when the game says
S.spots, S.nicknames = {}, {}   -- chest marks and your names for containers (same keys as Crafters Ledger)
S.settings = {view='Items', sort='Name'}
local dataVersion = 0   -- goes up whenever counts change, so pages redraw
local dirty = false

local function addName(name)
    if not valid(name) then return false end
    local k=string.lower(name)
    if names[k] then return false end
    names[k]=name; dirty=true
    return true
end

---------------------------------------------------------------------------------------------------
-- Saving and loading
local function save()
    if not DATA or type(io)~='table' or type(io.open)~='function' then return false end
    local ok,err=pcall(function()
        local f,e=io.open(DATA,'w'); if not f then error(e) end
        f:write('@version\t',VERSION,'\n')
        for key,v in pairs(S.settings) do f:write('@set\t',key,'\t',tostring(v),'\n') end
        for _,name in pairs(names) do f:write('@name\t',name,'\n') end
        for k,t in pairs(itemType) do if names[k] then f:write('@type\t',names[k],'\t',t,'\n') end end
        for _,o in pairs(found) do
            if valid(o.name) and not o.failed then
                if o.none then f:write('@none\t',o.name,'\t',tostring(o.at or 0),'\n')
                else
                    f:write('@item\t',o.name,'\t',tostring(o.at or 0),'\t',tostring(o.total),'\n')
                    for _,r in ipairs(o.rows) do
                        f:write('@row\t',o.name,'\t',r.place,'\t',(tostring(r.location or '')):gsub('[\t\r\n]',' '),'\t',
                            (tostring(r.container or '')):gsub('[\t\r\n]',' '),'\t',tostring(r.quantity),'\n')
                    end
                end
            end
        end
        for key,nick in pairs(S.nicknames) do f:write('@nickname\t',key,'\t',nick,'\n') end
        for key,sp in pairs(S.spots) do
            f:write('@spot\t',key,'\t',sp.raw,'\t',string.format('%.2f\t%.2f\t%.2f',sp.x,sp.y,sp.z),'\n')
        end
        f:close()
    end)
    if not ok then say('Save failed: '..tostring(err)); return false end
    dirty=false
    return true
end

local function readLines(path,fn)
    if not path or type(io)~='table' or type(io.open)~='function' then return end
    pcall(function()
        local f=io.open(path,'r'); if not f then return end
        for line in f:lines() do fn(line) end
        f:close()
    end)
end

local function load()
    readLines(DATA,function(line)
        local tag=line:match('^(@%a+)\t')
        if tag=='@name' then addName(line:match('^@name\t([^\t]+)$'))
        elseif tag=='@set' then
            local k,v=line:match('^@set\t([^\t]+)\t([^\t]*)$'); if k then S.settings[k]=v end
        elseif tag=='@type' then
            local n,t=line:match('^@type\t([^\t]+)\t([^\t]+)$'); if n then itemType[string.lower(n)]=t end
        elseif tag=='@none' then
            local n,at=line:match('^@none\t([^\t]+)\t(%d+)$')
            if n then found[string.lower(n)]={name=n,at=tonumber(at),none=true,total=0,rows={}} end
        elseif tag=='@item' then
            local n,at,total=line:match('^@item\t([^\t]+)\t(%d+)\t(%d+)$')
            if n then found[string.lower(n)]={name=n,at=tonumber(at),total=tonumber(total),rows={}} end
        elseif tag=='@row' then
            local n,place,loc,box,q=line:match('^@row\t([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(%d+)$')
            local o=n and found[string.lower(n)]
            if o then o.rows[#o.rows+1]={place=place,location=loc~='' and loc or nil,container=box~='' and box or nil,quantity=tonumber(q)} end
        elseif tag=='@nickname' then
            local k,nick=line:match('^@nickname\t([^\t]+)\t([^\t]+)$'); if k then S.nicknames[k]=nick end
        elseif tag=='@spot' then
            local k,raw,x,y,z=line:match('^@spot\t([^\t]+)\t([^\t]+)\t([%-%d%.]+)\t([%-%d%.]+)\t([%-%d%.]+)$')
            if k then S.spots[k]={raw=raw,x=tonumber(x),y=tonumber(y),z=tonumber(z)} end
        end
    end)
    -- Crafters Ledger: its shopping list names, and the chests you marked and named there
    readLines(CL_DATA,function(line)
        if line:sub(1,1)~='@' then
            local n=line:match('^(.-)\t%d+$'); if n then addName(n) end
        elseif line:sub(1,10)=='@nickname\t' then
            local k,nick=line:match('^@nickname\t([^\t]+)\t([^\t]+)$')
            if k and not S.nicknames[k] then S.nicknames[k]=nick end
        elseif line:sub(1,6)=='@spot\t' then
            local k,raw,x,y,z=line:match('^@spot\t([^\t]+)\t([^\t]+)\t([%-%d%.]+)\t([%-%d%.]+)\t([%-%d%.]+)$')
            if k and not S.spots[k] then S.spots[k]={raw=raw,x=tonumber(x),y=tonumber(y),z=tonumber(z)} end
        end
    end)
    dirty=false
end
load()

---------------------------------------------------------------------------------------------------
-- The scan: one account search at a time (the game answers one "search everywhere" at a time, a few
-- frames later, through a function). A name that never answers is usually not an exact item name.
local queue, queued = {}, {}
local inflight = nil            -- {k,name,at}
local clockNow = 0
local paused = false
local TIMEOUT, STALE, BACKOFF = 6, 6*3600, 5
local nextAt = 0
local scanned, scanTarget = 0, 0    -- this session's progress through a full scan

local function canSearch() return type(ShroudSearchOwnedItems)=='function' end
local function want(name,front)
    if not valid(name) then return end
    local k=string.lower(name)
    if inflight and inflight.k==k then return end
    if queued[k] then
        if not front then return end
        for i,n in ipairs(queue) do if string.lower(n)==k then table.remove(queue,i); break end end
    end
    queued[k]=true
    if front then table.insert(queue,1,name) else queue[#queue+1]=name end
end
local function isStale(o)
    if not o then return true end
    if o.failed then return clockNow-(o.failedAt or 0)>60 end
    local now=wallTime()
    return not (now and o.at and now-o.at<STALE)
end
local function store(name,res)
    local k=string.lower(name)
    -- a late answer (after its time ran out) still counts, but must not free another search's turn
    if inflight and inflight.k==k then inflight=nil; scanned=scanned+1 end
    dataVersion=dataVersion+1; dirty=true
    if type(res)~='table' then return end
    if field(res,'ok')==false then
        nextAt=clockNow+BACKOFF
        local o=found[k]
        if o and not o.failed then return end   -- keep what it had
        found[k]={name=name,failed=true,failedAt=clockNow,why=tostring(field(res,'error') or 'refused'),total=0,rows={}}
        return
    end
    local rows={}
    for _,r in ipairs(list(field(res,'rows'))) do
        if type(r)=='table' then
            rows[#rows+1]={place=tostring(field(r,'place') or 'unknown'),location=field(r,'location'),
                container=field(r,'container'),quantity=tonumber(field(r,'quantity')) or 0}
        end
    end
    local total=tonumber(field(res,'total')) or 0
    local shown=field(res,'name')
    if valid(shown) then names[k]=shown end
    found[k]={name=valid(shown) and shown or name,at=wallTime(),total=total,rows=rows,none=total==0 and #rows==0,
        truncated=field(res,'truncated')==true}
end
local function pump()
    if not canSearch() or paused then return end
    if inflight then
        if clockNow-inflight.at<=TIMEOUT then return end
        -- no answer: not an exact item name, or a slow search. Try it again in a minute.
        local k=inflight.k
        if not found[k] or found[k].failed then
            found[k]={name=inflight.name,failed=true,failedAt=clockNow,why='no answer',total=0,rows={}}
        end
        inflight=nil; scanned=scanned+1; dataVersion=dataVersion+1
    end
    if clockNow<nextAt or #queue==0 then return end
    local name=table.remove(queue,1)
    local k=string.lower(name); queued[k]=nil
    inflight={k=k,name=name,at=clockNow}
    local ok=pcall(ShroudSearchOwnedItems,name,function(res) store(name,res) end)
    if not ok then inflight=nil; nextAt=clockNow+BACKOFF end
end
-- Scan every name whose count is old (or every name, when everything=true)
function S.scan(everything)
    local n=0
    for k,name in pairs(names) do
        if everything or isStale(found[k]) then want(name); n=n+1 end
    end
    scanned, scanTarget = 0, #queue
    paused=false
    return n
end

---------------------------------------------------------------------------------------------------
-- Names from your recipes: built a few at a time (the game stops an add-on that takes too long in a frame)
local recipeJob = nil
local function startRecipeNames()
    if recipeJob then return true end
    local ok,book=false,nil
    if type(ShroudGetKnownRecipes)=='function' then ok,book=pcall(ShroudGetKnownRecipes) end
    if not ok or type(book)~='table' or next(book)==nil then return false end
    local l={}; for _,r in pairs(book) do l[#l+1]=r end
    recipeJob={list=l,i=1,added=0}
    return true
end
local function recipeStep()
    local j=recipeJob
    local start,done=clock(),0
    while j.i<=#j.list do
        local r=j.list[j.i]; j.i=j.i+1; done=done+1
        local d=r
        if field(r,'ingredients')==nil and field(r,'id')~=nil and type(ShroudGetRecipe)=='function' then
            local ok,v=pcall(ShroudGetRecipe,field(r,'id')); if ok and type(v)=='table' then d=v end
        end
        for _,res in ipairs(list(field(d,'results'))) do if addName(field(res,'name')) then j.added=j.added+1 end end
        for _,ing in ipairs(list(field(d,'ingredients'))) do
            if field(ing,'group')~=true and addName(field(ing,'name')) then j.added=j.added+1 end
            for _,c in ipairs(list(field(ing,'choices'))) do if addName(field(c,'name')) then j.added=j.added+1 end end
        end
        local t=clock()
        if (start and t and t-start>=0.004) or (not (start and t) and done>=20) then return false end
    end
    recipeJob=nil
    return true, j.added
end
local function bagNames()
    local ok,items=pcall(ShroudGetInventoryItems)
    if not ok or type(items)~='table' then return {} end
    local out={}
    for _,it in pairs(items) do
        local n=field(it,'name')
        if valid(n) then
            addName(n); out[#out+1]=n
            local t=field(it,'itemType'); if valid(t) then itemType[string.lower(n)]=t end
        end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Places: your bag, a bank, each house lot, other characters, mail...; each with the containers in it
local PLACE_NAMES={carried='Bag',bank='Bank',houseStorage='House',otherCharacters='Other character',
    mail='Mail',crafting='Crafting',vendorListings='Vendor',ransom='Ransom',unknown='Other'}
local PLACE_RANK={carried=1,bank=2,houseStorage=3,otherCharacters=4,mail=5,vendorListings=6}
local LOOSE='Not in a container'
-- The game's location can carry an internal scene name ("Ivory Stronghold: BasementSceneDungeonTown_Arena
-- (Town Lot Basement)"): show "Ivory Stronghold (Town Lot Basement)". Keys keep the full text.
local function niceLocation(loc)
    local out=tostring(loc or '')
    out=out:gsub(':%s*[%w_]*Scene[%w_]*',''):gsub(':%s*%w+_[%w_]+','')
    out=out:gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
    return out
end
local function placeLabel(place,loc)
    local where=niceLocation(tostring(loc or ''):gsub('^Inventory:%s*',''):gsub('^Bank:%s*',''):gsub('%s*%(in a container%)',''))
    return (PLACE_NAMES[place] or place)..(where~='' and (': '..where) or '')
end
local function spotKey(loc,box) return string.lower(tostring(loc)..'|'..tostring(box)) end
local function shownBox(loc,box) return S.nicknames[spotKey(loc,box)] or box end

-- Every container that holds something, with its contents
local function chests()
    local byKey,out={},{}
    for _,o in pairs(found) do
        if not o.none and not o.failed then
            for _,r in ipairs(o.rows) do
                local loc=tostring(r.location or ''):gsub('%s*%(in a container%)','')
                local box=(r.container and r.container~='') and r.container or LOOSE
                local key=r.place..'|'..loc..'|'..box
                local c=byKey[key]
                if not c then
                    c={key=key,place=r.place,loc=loc,box=box,items={},total=0}
                    byKey[key]=c; out[#out+1]=c
                end
                c.items[#c.items+1]={name=o.name,qty=r.quantity}
                c.total=c.total+r.quantity
            end
        end
    end
    table.sort(out,function(a,b)
        local ra,rb=PLACE_RANK[a.place] or 9,PLACE_RANK[b.place] or 9
        if ra~=rb then return ra<rb end
        if a.loc~=b.loc then return a.loc<b.loc end
        return shownBox(a.loc,a.box)<shownBox(b.loc,b.box)
    end)
    for _,c in ipairs(out) do table.sort(c.items,function(a,b) return a.name<b.name end) end
    return out
end
-- An item's containers, outside your own bag (bag stacks don't count as scattered)
local function storedIn(o)
    local seen,n={},0
    for _,r in ipairs(o.rows) do
        if r.place~='carried' then
            local key=r.place..'|'..tostring(r.location)..'|'..tostring(r.container or LOOSE)
            if not seen[key] then seen[key]=true; n=n+1 end
        end
    end
    return n
end

---------------------------------------------------------------------------------------------------
-- The compass: stand by a chest and Mark it once; Compass then points the game's compass at it
local beaconOn=nil
local function hereRaw()
    if type(ShroudGetCurrentSceneNameRaw)~='function' then return nil end
    local ok,raw=pcall(ShroudGetCurrentSceneNameRaw)
    if ok and type(raw)=='string' and raw~='' then return raw end
end

---------------------------------------------------------------------------------------------------
-- The window
local UI,win,el = nil,nil,{}
local page = {Items=1,Chests=1,Scattered=1}
local open = {}                 -- expanded rows: 'item|<lower>' or 'chest|<key>'
local naming = nil              -- the container whose name box is open
local query = ''
local PAGE = 10
local CHEST_SHOW = 40           -- items shown inside an opened chest (element limits)
local render
local function msg(s) if el.message then el.message:SetText(s) end; say(s) end
local function label(text,width)
    return UI.Label{text=tostring(text),style={width=width,flexShrink=width and 0 or 1,flexGrow=0,whiteSpace='wrap',fontSize=13}}
end
local function flexLabel(text,size,color)
    return UI.Label{text=tostring(text),style={flexGrow=1,flexShrink=1,whiteSpace='wrap',fontSize=size or 13,color=color}}
end
local function row(children) return UI.Row{style={alignItems='center',marginTop=4,flexShrink=0},children=children} end
local function spacer(w) return UI.Label{text='',style={width=w,flexShrink=0}} end
local function toggle(key)
    local b
    b=UI.Button{text=open[key] and '-' or '+',style={width=32},onClick=function() open[key]=not open[key]; render() end}
    return b
end

local function markSpot(loc,box)
    local x,y,z=ShroudPlayerX,ShroudPlayerY,ShroudPlayerZ
    local raw=hereRaw()
    if type(x)~='number' or type(y)~='number' or type(z)~='number' or x~=x or not raw then
        msg('Your position is not available right now. Try again in a moment.'); return
    end
    S.spots[spotKey(loc,box)]={raw=raw,x=x,y=y,z=z}; save()
    msg('Marked where you stand as '..shownBox(loc,box)..'. Compass will point here from anywhere in this scene.')
end
local function clearCompass()
    local ok=type(ShroudClearBeacon)=='function' and pcall(ShroudClearBeacon)
    beaconOn=nil
    msg(ok and 'Compass cleared.' or 'Type /beacon clear to clear the compass.')
end
local function pointAt(loc,box)
    local key=spotKey(loc,box)
    local sp=S.spots[key]; if not sp then return end
    if hereRaw()~=sp.raw then msg(shownBox(loc,box)..' is in '..niceLocation(loc)..'. Go there, then click Compass again.'); return end
    if type(ShroudSetBeacon)~='function' then msg('This game client cannot set the compass.'); return end
    local ok,set=pcall(ShroudSetBeacon,sp.x,sp.y,sp.z,tostring(shownBox(loc,box)):gsub('[%[%]<>]',''):sub(1,40))
    if ok and set~=false then beaconOn=key; msg('Your compass points at '..shownBox(loc,box)..'. Click Clear compass to remove it.')
    else msg('The game did not set the compass right now. Try again in a moment.') end
end
-- Compass, Mark, Name for one container line (houses, banks and other storage you can walk to)
local function chestButtons(place,loc,box,parts)
    local key=spotKey(loc,box)
    if place=='houseStorage' or place=='bank' or place=='unknown' then
        local known=S.spots[key]~=nil
        if known then
            local pointing=beaconOn==key
            parts[#parts+1]=UI.Button{text=pointing and 'Clear compass' or 'Compass',style={width=pointing and 130 or 90},
                tooltip='Point your compass at it (works in its scene)',
                onClick=function() if beaconOn==key then clearCompass() else pointAt(loc,box) end; render() end}
        end
        parts[#parts+1]=UI.Button{text=known and 'Re-mark' or 'Mark',style={width=80},
            tooltip='Stand next to it and click to remember where it is, for the compass',
            onClick=function() markSpot(loc,box); render() end}
        if known then
            parts[#parts+1]=UI.Button{text='Unmark',style={width=80},tooltip='Forget where it is',
                onClick=function() if beaconOn==key then clearCompass() end; S.spots[key]=nil; save(); render() end}
        end
    end
    if box~=LOOSE then
        parts[#parts+1]=UI.Button{text='Name',style={width=70},tooltip='Give it a name of your own, like Reagent Chest',
            onClick=function() naming=(naming~=key) and key or nil; render() end}
    end
end
local function nameBox(parent,loc,box)
    local key=spotKey(loc,box)
    if naming~=key then return end
    local f
    local function saveName()
        local nick=trim(f:GetText())
        if nick=='' then S.nicknames[key]=nil
        elseif not valid(nick) then msg('That name can not be used.'); return
        else S.nicknames[key]=nick end
        naming=nil; save(); render()
    end
    f=UI.TextField{text=S.nicknames[key] or '',placeholder='Your name for it, e.g. Reagent Chest',maxLength=40,style={flexGrow=1},onSubmit=saveName}
    parent:Add(row{f,UI.Button{text='Save',style={width=70},onClick=saveName},
        UI.Button{text='Cancel',style={width=80},onClick=function() naming=nil; render() end}})
end

-- Items page: everything you own, by name or amount; + shows each place with its containers
local function ownedList()
    local words={}
    for w in query:gmatch('%S+') do words[#words+1]=w end
    local out={}
    for k,o in pairs(found) do
        if not o.none and not o.failed and o.total>0 then
            local ok=true
            for _,w in ipairs(words) do if not k:find(w,1,true) then ok=false; break end end
            if ok then out[#out+1]=o end
        end
    end
    local sort=S.settings.sort
    table.sort(out,function(a,b)
        if sort=='Amount' and a.total~=b.total then return a.total>b.total end
        if sort=='Places' then local pa,pb=storedIn(a),storedIn(b); if pa~=pb then return pa>pb end end
        return a.name<b.name
    end)
    return out
end
local function itemPlaces(parent,o)
    local places,order={},{}
    for _,r in ipairs(o.rows) do
        local loc=tostring(r.location or ''):gsub('%s*%(in a container%)','')
        local pk=r.place..'|'..loc
        local p=places[pk]
        if not p then p={place=r.place,loc=loc,total=0,boxes={},order={}}; places[pk]=p; order[#order+1]=p end
        local box=(r.container and r.container~='') and r.container or LOOSE
        if not p.boxes[box] then p.boxes[box]=0; p.order[#p.order+1]=box end
        p.boxes[box]=p.boxes[box]+r.quantity; p.total=p.total+r.quantity
    end
    table.sort(order,function(a,b) return (PLACE_RANK[a.place] or 9)<(PLACE_RANK[b.place] or 9) end)
    for _,p in ipairs(order) do
        parent:Add(row{spacer(32),flexLabel(placeLabel(p.place,p.loc),13,'@gold'),label(p.total,80)})
        for _,box in ipairs(p.order) do
            local parts={spacer(64),flexLabel(shownBox(p.loc,box)..(S.nicknames[spotKey(p.loc,box)] and ('  ('..box..')') or '')),label(p.boxes[box],80)}
            chestButtons(p.place,p.loc,box,parts)
            parent:Add(row(parts))
            nameBox(parent,p.loc,box)
        end
    end
    if o.truncated then parent:Add(label('The game cut this list short; the total is still complete.')) end
end

local function pager(listLen,key)
    local pages=math.max(1,math.ceil(listLen/PAGE))
    page[key]=math.max(1,math.min(page[key],pages))
    return pages,(page[key]-1)*PAGE+1,math.min(page[key]*PAGE,listLen)
end

local function renderItems(body)
    local l=ownedList()
    local pages,a,b=pager(#l,'Items')
    if #l==0 then
        body:Add(label(next(found) and 'Nothing matches. Try part of a name, like pearl or ore.'
            or 'No counts yet. Click Scan everything to look up everything you own.'))
    end
    for i=a,b do
        local o=l[i]; local key='item|'..string.lower(o.name)
        local n=storedIn(o)
        local box=UI.Column{style={paddingTop=4,paddingBottom=4,flexShrink=0}}
        box:Add(row{toggle(key),flexLabel(o.name,15),label(o.total..' total',110),label(n..(n==1 and ' chest' or ' chests'),90),
            UI.Button{text='Recount',style={width=85},tooltip='Ask the game again now',onClick=function() want(o.name,true); msg('Recounting '..o.name..'...') end}})
        if open[key] then itemPlaces(box,o) end
        body:Add(box)
    end
    el.pageLabel:SetText(#l..' items you own | page '..page.Items..' / '..pages)
end

local function renderChests(body)
    local l=chests()
    local words={}; for w in query:gmatch('%S+') do words[#words+1]=w end
    if #words>0 then
        local keep={}
        for _,c in ipairs(l) do
            local hay=string.lower(shownBox(c.loc,c.box)..' '..c.box..' '..placeLabel(c.place,c.loc))
            local ok=true; for _,w in ipairs(words) do if not hay:find(w,1,true) then ok=false; break end end
            if ok then keep[#keep+1]=c end
        end
        l=keep
    end
    local pages,a,b=pager(#l,'Chests')
    if #l==0 then body:Add(label('No containers yet. Click Scan everything first.')) end
    local lastPlace=nil
    for i=a,b do
        local c=l[i]; local key='chest|'..c.key
        -- one heading per place: your bag, each bank, each house lot
        local where=placeLabel(c.place,c.loc)
        if where~=lastPlace then
            lastPlace=where
            body:Add(UI.Label{text=where,class='heading',style={fontSize=15,color='@gold',marginTop=8,flexShrink=0}})
        end
        local box=UI.Column{style={paddingTop=4,paddingBottom=4,flexShrink=0}}
        local nick=S.nicknames[spotKey(c.loc,c.box)]
        local parts={toggle(key),flexLabel(shownBox(c.loc,c.box)..(nick and ('  ('..c.box..')') or ''),15),
            label(#c.items..(#c.items==1 and ' item' or ' items')..' | '..c.total,150)}
        chestButtons(c.place,c.loc,c.box,parts)
        box:Add(row(parts))
        nameBox(box,c.loc,c.box)
        if open[key] then
            for j=1,math.min(#c.items,CHEST_SHOW) do
                local it=c.items[j]
                box:Add(row{spacer(40),flexLabel(it.name),label(it.qty,80)})
            end
            if #c.items>CHEST_SHOW then box:Add(row{spacer(40),label('...and '..(#c.items-CHEST_SHOW)..' more. Search for them on the Items page.')}) end
        end
        body:Add(box)
    end
    el.pageLabel:SetText(#l..' containers | page '..page.Chests..' / '..pages)
end

local function renderScattered(body)
    local l={}
    for _,o in pairs(found) do
        if not o.none and not o.failed and storedIn(o)>=2 then l[#l+1]=o end
    end
    table.sort(l,function(a,b) local pa,pb=storedIn(a),storedIn(b); if pa~=pb then return pa>pb end; return a.total>b.total end)
    local pages,a,b=pager(#l,'Scattered')
    body:Add(label('Items kept in more than one chest or bank container, the most spread out first. Your own bag does not count.'))
    if #l==0 then body:Add(label('Nothing scattered found yet.')) end
    for i=a,b do
        local o=l[i]; local key='scat|'..string.lower(o.name)
        local box=UI.Column{style={paddingTop=4,paddingBottom=4,flexShrink=0}}
        box:Add(row{toggle(key),flexLabel(o.name,15),label(storedIn(o)..' places',90),label(o.total..' total',110)})
        if open[key] then itemPlaces(box,o) end
        body:Add(box)
    end
    el.pageLabel:SetText(#l..' scattered items | page '..page.Scattered..' / '..pages)
end

local function statusText()
    local n,own=0,0
    for _ in pairs(names) do n=n+1 end
    for _,o in pairs(found) do if not o.none and not o.failed and o.total>0 then own=own+1 end end
    local s=n..' item names known | '..own..' items you own'
    if not canSearch() then return s..' | This game client cannot count your bank or chests (needs Lua API 55).' end
    if recipeJob then s=s..' | Reading your recipes...' end
    if paused and #queue>0 then return s..' | Scan paused, '..#queue..' left' end
    if #queue>0 or inflight then
        return s..' | Scanning: '..math.min(scanned,scanTarget)..' of '..scanTarget..' done, about '..math.ceil((#queue+1)*0.25/60)..' min left'
    end
    return s..' | Up to date'
end

local viewButtons={}
render=function()
    if not el.body then return end
    el.renderedAt=clockNow
    el.body:Clear()
    local v=S.settings.view
    for name,b in pairs(viewButtons) do b:SetText(name==v and ('['..name..']') or name) end
    if v=='Chests' then renderChests(el.body) elseif v=='Scattered' then renderScattered(el.body) else renderItems(el.body) end
    el.renderedVersion=dataVersion
end

local function buildUI()
    UI=Shroud.UI
    el={}
    viewButtons={}
    for _,v in ipairs({'Items','Chests','Scattered'}) do
        viewButtons[v]=UI.Button{text=v,onClick=function() S.settings.view=v; open={}; naming=nil; render() end}
    end
    el.search=UI.TextField{text=query,placeholder='Search items or chests, any words, e.g. black pearl',style={flexGrow=1},
        onSubmit=function() query=string.lower(trim(el.search:GetText())); page.Items=1; page.Chests=1; render() end}
    local sortPick=UI.Dropdown{choices={'Name','Amount','Places'},value=S.settings.sort or 'Name',style={width=120},
        tooltip='How the Items page is sorted',onChange=function(_,v) S.settings.sort=v; render() end}
    el.body=UI.Column{style={flexShrink=0,paddingRight=18}}
    el.pageLabel=label('')
    el.status=label('')
    el.message=label('Strongbox looks up every item name it knows and remembers where your things are.')
    local function findName()
        -- an exact name nothing else knows: add it and look it up now
        local n=trim(el.search:GetText())
        if not valid(n) then msg('Type the exact item name in the search box first.'); return end
        addName(n); want(n,true); msg('Looking up "'..n..'" by its exact name...')
    end
    win=UI.Window{id='strongbox_main',title='Strongbox',width=960,height=660,minWidth=760,minHeight=420,x=90,y=80,escCloses=true,
        style={paddingLeft=16,paddingRight=16,paddingTop=10,paddingBottom=10},children={
            row{viewButtons.Items,viewButtons.Chests,viewButtons.Scattered,UI.Label{text='',style={flexGrow=1}},
                UI.Button{text='Scan everything',tooltip='Look up every item name again (about a quarter second each)',
                    onClick=function() local n=S.scan(true); msg('Scanning '..n..' item names in the background.') end},
                UI.Button{text='Pause',onClick=function() paused=not paused; msg(paused and 'Scan paused.' or 'Scan resumed.') end}},
            row{el.search,UI.Button{text='Find',onClick=function() query=string.lower(trim(el.search:GetText())); page.Items=1; page.Chests=1; render() end},
                UI.Button{text='Look up exact name',tooltip='For an item none of your recipes or bags mention',onClick=findName},
                label('Sort',40),sortPick},
            el.status,
            UI.Scroll{id='strongbox_scroll',style={height=0,flexGrow=1,flexShrink=1},children={el.body}},
            row{UI.Button{text='Previous',onClick=function() local v=S.settings.view; page[v]=math.max(1,(page[v] or 1)-1); render() end},
                el.pageLabel,UI.Button{text='Next',onClick=function() local v=S.settings.view; page[v]=(page[v] or 1)+1; render() end}},
            el.message,
        }}
    render(); win:Show()
end

---------------------------------------------------------------------------------------------------
-- Commands, launcher and the update loop
local openRequested,toggleRequested,launcher=false,false,nil
function S.open() openRequested=true end
function S.toggle() toggleRequested=true end
local function openWindow() if not win then buildUI() else win:Show(); render() end end

function ShroudOnStart()
    if Shroud and Shroud.Command then
        if not pcall(Shroud.Command,'strongbox',function() S.open() end) then say('Use /lua code Strongbox.open() to open it.') end
    end
    if Shroud and Shroud.Keybind then
        pcall(Shroud.Keybind,{id='toggle',label='Show/hide Strongbox',onPress=function() S.toggle() end})
    end
    local ok,err=pcall(function()
        UI=Shroud.UI
        if UI.HudFrame then
            local texture=-1
            if type(ShroudLoadTexture)=='function' then
                for _,path in ipairs({'strongbox/icon.png','icon.png'}) do
                    local loaded,id=pcall(ShroudLoadTexture,path)
                    if loaded and type(id)=='number' and id>=0 then texture=id; break end
                end
            end
            local button
            if texture>=0 and UI.IconButton then
                button=UI.IconButton{texture=texture,tooltip='Strongbox - where your things are',style={width=46,height=46},onClick=function() S.toggle() end}
            else
                button=UI.Button{text='Box',tooltip='Strongbox',style={width=46,height=46},onClick=function() S.toggle() end}
            end
            launcher=UI.HudFrame{id='strongbox_launcher',x=20,y=360,width=50,height=50,children={button}}
        end
    end)
    if not ok then say('Launcher button unavailable: '..tostring(err)) end
    say('v'..VERSION..' loaded. Open it with /strongbox or the strongbox icon.')
end

-- What you pick up or loot: new names, and a fresh count for them
function ShroudOnItemsGained(items)
    for _,it in pairs(list(items)) do
        local n=field(it,'name')
        if valid(n) then addName(n); want(n) end
    end
end
-- Your bag changed: count its items again soon
local bagChanged=false
function ShroudOnInventoryChanged() bagChanged=true end

local warmAt,saveTimer,fast,bagTimer=5,0,0,0
function ShroudOnUpdate()
    local dt=tonumber(ShroudDeltaTime) or 0
    clockNow=clockNow+dt
    if toggleRequested then
        toggleRequested=false
        local ok,err=pcall(function() if win and win:IsShown() then win:Hide() else openWindow() end end)
        if not ok then say('Could not open: '..tostring(err)) end
    end
    if openRequested then
        openRequested=false
        local ok,err=pcall(openWindow); if not ok then say('Could not open: '..tostring(err)) end
    end
    local ok,err=pcall(function()
        -- shortly after login: read your recipes and bag for names, then count anything not counted lately
        if warmAt then
            warmAt=warmAt-dt
            if warmAt<=0 then
                warmAt=nil
                bagNames()
                if not startRecipeNames() then warmAt=10 end
            end
        end
        if recipeJob then
            local done=recipeStep()
            if done then S.scan(false) end
        end
        if bagChanged then
            bagTimer=bagTimer+dt
            if bagTimer>=3 then
                bagChanged,bagTimer=false,0
                for _,n in ipairs(bagNames()) do local o=found[string.lower(n)]; if o then o.at=0 end; want(n) end
            end
        end
        pump()
    end)
    if not ok then say('Scan stopped: '..tostring(err)); inflight=nil end
    fast=fast+dt
    if fast>=0.5 then
        fast=0
        if win then
            pcall(function()
                if not win:IsShown() then return end
                el.status:SetText(statusText())
                -- redraw with new counts: right away once a scan is done, every 15 s while one runs
                local busy=#queue>0 or inflight~=nil
                if el.renderedVersion~=dataVersion and not naming and clockNow-(el.renderedAt or 0)>=(busy and 15 or 1) then
                    el.renderedAt=clockNow; render()
                end
            end)
        end
    end
    saveTimer=saveTimer+dt
    if saveTimer>=60 then saveTimer=0; if dirty then save() end end
end
function ShroudOnDisableScript()
    if dirty then save() end
    if win then pcall(function() win:Destroy() end); win=nil end
    if launcher then pcall(function() launcher:Destroy() end); launcher=nil end
end
