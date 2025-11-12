-- deterministic dungeon generation harness
local harness={}

harness.default_seeds={1111,2222,3333,4444,5555}

local function validate_locked_edges(issues)
 if not gen_locked_edges then return end
 for edge in all(gen_locked_edges) do
  if edge.locked and edge.keynum then
   local lt=edge.lock_tile
   if not lt then
    add(issues,"edge "..edge.n1.index.."->"..edge.n2.index.." missing lock tile")
   else
    local tile=get_wall(lt.x,lt.y)
    if tile~=door_locked then
     add(issues,"door at "..lt.x..","..lt.y.." not locked")
    end
   end
   local key_found=false
   for ob in all(gen_objects) do
    if ob.typ==obj_types.key and ob.keynum==edge.keynum then
     key_found=true
     break
    end
   end
   if not key_found then
    add(issues,"missing key#"..edge.keynum.." for edge "..edge.n1.index.."->"..edge.n2.index)
   end
  end
 end
end

function harness.run(seeds)
 seeds=seeds or harness.default_seeds
 local summary={
  total=#seeds,
  failures=0,
  results={}
 }
 local original_seed=nil
 for _,seed in ipairs(seeds) do
  local ok,meta=pcall(function()
   local _,stats=generate_dungeon({seed=seed})
   return stats
  end)
  local record={seed=seed,issues={},rooms=0,objects=0}
  if not ok then
   record.error=meta
   summary.failures+=1
  else
   record.rooms=meta.rooms or 0
   record.objects=meta.objects or 0
   if record.rooms<(gen_params.min_rooms or 0) then
    add(record.issues,"room count "..record.rooms.." below min "..gen_params.min_rooms)
   end
   validate_locked_edges(record.issues)
   if #record.issues>0 then
    summary.failures+=1
   end
  end
  add(summary.results,record)
 end
 return summary
end

dungeon_harness=harness
return harness

