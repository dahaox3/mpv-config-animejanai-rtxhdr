-- Shared owner of AI mode, render backend and the final RTX HDR vf stage.
local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = {movie_hwdec='auto-copy-safe'}
require('mp.options').read_options(options, 'hybrid')
local conf_path = mp.command_native({'expand-path', '~~/../animejanai/animejanai.conf'})
local names = {[0]='关闭', [1001]='Quality 质量档', [1002]='Balanced 平衡档', [1003]='Performance 性能档'}
local function read_conf()
    local f = io.open(conf_path, 'r')
    if not f then return '', {} end
    local text = f:read('*a'); f:close()
    local global, section = {}, ''
    for line in text:gmatch('[^\r\n]+') do
        local s = line:match('^%s*%[([^%]]+)%]')
        if s then section = s:lower()
        elseif section == 'global' then
            local k,v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
            if k then global[k:lower()] = v end
        end
    end
    return text, global
end
local _, initial = read_conf()
-- Missing or unchecked Manager default means Off, never implicit Balanced.
local slot = math.max(0, tonumber(initial.default_slot) or 0)
local rtx, applying = false, false
local effective_api

local function hdr_filter()
    return {name='d3d11vpp',label='rtx-hdr',enabled=true,params={['nvidia-true-hdr']='yes'}}
end
local function others(filters)
    local result={}
    for _,f in ipairs(filters or {}) do
        if f.label~='aji' and f.label~='rtx-hdr' and f.label~='hybrid-cuda-upload'
        and f.label~='hybrid-cuda-bridge' then result[#result+1]=f end
    end
    return result
end
local function set(name,value)
    local ok,err=mp.set_property_native(name,value)
    if not ok then error(name..': '..tostring(err)) end
end
local function apply_pipeline()
    local _,global=read_conf()
    local backend=(global.backend or 'TensorRT'):lower()
    local directml=slot>0 and (backend=='directml' or backend=='ncnn')
    local bridge=slot>0 and rtx and not directml
    local api=(slot>0 and not directml and not bridge) and 'vulkan' or 'd3d11'
    local hwdec=options.movie_hwdec
    if slot>0 then hwdec=bridge and 'auto-copy-safe' or (directml and 'd3d11va' or 'nvdec') end
    local clean=others(mp.get_property_native('vf'))
    applying=true
    if effective_api~=api then
        -- Remove device-specific filters before changing the VO context.
        set('vf',clean)
        -- Break the old device-frame interop before creating the other API.
        set('hwdec','auto-copy-safe')
        set('gpu-api',api)
        set('vo','gpu-next')
        set('hwdec',hwdec)
        effective_api=api
    else set('hwdec',hwdec) end
    local filters={}
    if bridge then
        filters[#filters+1]={name='lavfi',label='hybrid-cuda-upload',enabled=true,
            params={graph='format=p010le,hwupload_cuda'}}
    end
    if slot>0 then
        filters[#filters+1]={name='animejanai',label='aji',enabled=true,params={
            lib=mp.command_native({'expand-path','~~/../animejanai/inference/aji.dll'}),
            conf=conf_path,
            ['model-dir']=mp.command_native({'expand-path','~~/../animejanai/onnx'}),
            ['rife-model-dir']=mp.command_native({'expand-path','~~/../animejanai/rife'}),
            trtexec=mp.command_native({'expand-path','~~/../animejanai/inference/trtexec.exe'}),
            stats=mp.command_native({'expand-path','~~/../animejanai/currentanimejanai.log'}),
            slot=tostring(slot),
            ['output-444']=not directml and 'yes' or 'no',
        }}
    end
    if bridge then
        filters[#filters+1]={name='cuda-d3d11',label='hybrid-cuda-bridge',enabled=true}
    end
    for _,f in ipairs(clean) do filters[#filters+1]=f end
    if rtx then filters[#filters+1]=hdr_filter() end
    set('user-data/hybrid/slot',slot)
    set('user-data/hybrid/rtx-hdr',rtx)
    set('user-data/hybrid/gpu-bridge',bridge)
    set('user-data/hybrid/backend',slot>0 and (directml and 'DirectML' or 'TensorRT') or 'Off')
    set('vf',filters)
    applying=false
    msg.info(string.format('slot=%d, RTX HDR=%s, gpu-api=%s, hwdec=%s',slot,tostring(rtx),api,hwdec))
end
local function apply()
    local ok,err=pcall(apply_pipeline)
    applying=false
    if not ok then msg.error(tostring(err)); mp.osd_message('视频处理设置失败，请查看控制台。',5) end
    return ok
end
mp.register_script_message('hybrid-mode',function(value)
    local n=tonumber(value)
    if not n or n<0 or n>9999 then return end
    slot=n
    if slot>0 then mp.set_property_native('glsl-shaders',{}) end
    if apply() then mp.osd_message('AnimeJaNai：'..(names[slot] or ('自定义档位 '..slot)),3) end
end)
mp.register_script_message('hybrid-shader',function(profile)
    slot=0
    if apply() then mp.commandv('apply-profile',profile); mp.osd_message('着色器模式：'..profile,3) end
end)
mp.register_script_message('hybrid-rtx-hdr',function(value)
    if value=='on' or value=='yes' then rtx=true
    elseif value=='off' or value=='no' then rtx=false
    else rtx=not rtx end
    if apply() then
        local note=rtx and 'RTX HDR：开启（SDR 转 HDR）' or 'RTX HDR：关闭'
        if rtx and mp.get_property_native('user-data/hybrid/gpu-bridge') then note=note..'\nTensorRT + GPU 显存桥接' end
        mp.osd_message(note,4)
    end
end)
mp.register_script_message('hybrid-vf-toggle',function(spec)
    applying=true
    local filters=mp.get_property_native('vf') or {}
    for i=#filters,1,-1 do if filters[i].label=='rtx-hdr' then table.remove(filters,i) end end
    mp.set_property_native('vf',filters)
    mp.commandv('vf','toggle',spec)
    applying=false
    apply()
end)
-- Other plugins and console commands may change vf without going through us.
-- Reconcile the managed HDR stage to the tail whenever that happens.
mp.observe_property('vf','native',function(_,filters)
    if applying or not rtx then return end
    -- Observer payloads can be stale after several changes in one player tick.
    filters=mp.get_property_native('vf') or {}
    local count=0
    for _,f in ipairs(filters) do if f.label=='rtx-hdr' then count=count+1 end end
    local last=filters[#filters]
    if count==1 and last and last.label=='rtx-hdr' and last.enabled~=false then return end
    local ordered={}
    for _,f in ipairs(filters) do if f.label~='rtx-hdr' then ordered[#ordered+1]=f end end
    ordered[#ordered+1]=hdr_filter()
    applying=true
    mp.set_property_native('vf',ordered)
    applying=false
end)
mp.register_script_message('hybrid-menu',function()
    local items={}
    for _,n in ipairs({1001,1002,1003,0}) do items[#items+1]={title=names[n],value='script-message hybrid-mode '..n} end
    items[#items+1]={title='模型 / 自定义档位管理器',value='run "~~/../AnimeJaNaiManager.exe"'}
    items[#items+1]={title='RTX HDR：'..(rtx and '开启' or '关闭'),value='script-message hybrid-rtx-hdr'}
    mp.commandv('script-message-to','uosc','open-menu',utils.format_json({type='animejanai',title='视频增强（启动默认关闭）',items=items}))
end)
mp.add_hook('on_load',30,apply)
apply()
