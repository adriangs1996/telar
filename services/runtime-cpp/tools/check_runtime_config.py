#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


JSON_ASSERTIONS = r'''
local decode = require('telar').json.decode
local value = decode([[{"array":[1,null,false,"café\uD83D\uDE00"],"nested":{"nul\u0000key":true}}]])
assert(value.array[1] == 1 and value.array[2] == nil and value.array[3] == false and value.array[4] == 'café😀')
assert(value.nested['nul\0key'])
assert(math.type(decode('9223372036854775807')) == 'integer')
assert(math.type(decode('9223372036854775808')) == 'float')
assert(math.type(decode('1.0')) == 'float')
assert(decode('1e309') == math.huge and decode('1e-999') == 0)
for _, input in ipairs({'', '01', '1.', '[1,]', '{"a":null,"\\u0061":0}', '"\\ud800"', '"'..string.char(255)..'"'}) do
  assert(not pcall(decode,input), input)
end
assert(not pcall(decode, {}))
assert(not pcall(decode, string.rep(' ',1024*1024+1)))
assert(decode(string.rep('[',63)..'0'..string.rep(']',63)))
assert(not pcall(decode, string.rep('[',64)..'0'..string.rep(']',64)))
return {api_version=2}
'''



def graphics_cases():
    for name, value in {
        "defaults": "{}", "minimum": "{pane_mib=2,global_mib=2}",
        "maximum": "{pane_mib=256,global_mib=512}", "strings": "{pane_mib='4',global_mib='8'}",
        "integer_float": "{pane_mib=8.0,global_mib=16.0}", "pane_only": "{pane_mib=32}",
        "global_only": "{global_mib=256}",
    }.items():
        yield {"name": "graphics_config_" + name, "source": "return {api_version=2,runtime={graphics=" + value + "}}"}
    for name, value in {
        "type": "true", "pane_too_small": "{pane_mib=1}", "pane_too_big": "{pane_mib=257}",
        "global_too_small": "{pane_mib=4,global_mib=2}", "global_too_big": "{global_mib=513}",
        "pane_negative": "{pane_mib=-2}", "fraction": "{pane_mib=2.5}",
        "non_integer": "{pane_mib='two'}", "field": "{pane_mb=4}", "infinity": "{pane_mib=math.huge}",
    }.items():
        yield {"name": "graphics_config_invalid_" + name, "source": "return {api_version=2,runtime={graphics=" + value + "}}", "valid": False}
    yield {"name": "graphics_config_profile", "source": "return {api_version=2,runtime={graphics={pane_mib=16,global_mib=32}},profiles={selected={runtime={graphics={global_mib=16}}}}}", "arguments": ["--profile", "selected"]}


def cases():
    yield from graphics_cases()
    yield from bar_cases()
    yield from definition_cases()
    yield from binding_cases()
    yield from client_cases()
    yield from appearance_cases()
    yield {"name": "json", "source": JSON_ASSERTIONS}
    yield {"name": "local_modules", "source": "local a=require('local'); assert(a==require('local') and loads==1); return a",
           "module": "loads=(loads or 0)+1; return {api_version=2}"}
    yield {"name": "relative_paths", "source": "return {api_version=2, runtime={history={path='sub/../custom.db'}, session={persist=false}}}", "history": "custom.db"}
    yield {"name": "background_config", "source": "return {api_version=2, runtime={history={path='custom.db'}, session={persist=false}}}", "history": "custom.db", "background": True}
    yield {"name": "implicit_config", "source": "return {api_version=2, runtime={history={path='custom.db'}}}", "implicit": True, "history": "custom.db"}
    yield {"name": "development_config", "source": "return {api_version=2, runtime={history={path='custom.db'}}}", "development": True, "history": "custom.db"}
    yield {"name": "config_disabled", "source": "error('must not execute')", "implicit": True, "arguments": ["--no-config"]}
    yield {"name": "profile", "source": "return {api_version=2, profiles={selected={runtime={history={path='selected.db'},session={persist=false}}}}}", "arguments": ["--profile", "selected"], "history": "selected.db"}
    yield {"name": "agent_limits", "source": "local a={}; for i=1,28 do a[i]={name='custom'..i} end; a[28].working=false; a[1].working={string.rep('x',65),'kept'}; return {api_version=2,runtime={agents=a}}", "notices": ["agent_manifest.max_custom_agents", "agent_manifest.max_phrase_bytes"]}
    yield {"name": "builtin_extension", "source": "return {api_version=2,runtime={agents={{name='claude',working={'custom'},icon='é'}, {name='claude',attachments='ordered'}}}}"}
    for name, source in {
        "api_version": "return {api_version=1}",
        "unknown_runtime_field": "return {api_version=2, runtime={unknown=true}}",
        "unused_profile": "return {api_version=2, profiles={unused={runtime={history={output='invalid'}}}}}",
        "duplicate_agent": "return {api_version=2, runtime={agents={{name='custom'},{name='custom'}}}}",
        "agent_name": "return {api_version=2, runtime={agents={{name='Uppercase'}}}}",
        "wide_icon": "return {api_version=2, runtime={agents={{name='custom',icon='好'}}}}",
        "control_phrase": "return {api_version=2, runtime={agents={{name='custom',working={'line\\n'}}}}}",
        "invalid_utf8": "return {api_version=2, runtime={agents={{name='custom',working={string.char(255)}}}}}",
        "agent_list_hole": "return {api_version=2, runtime={agents={[2]={name='custom'}}}}",
        "empty_command": "return {api_version=2, runtime={engine={command={}}}}",
        "helper_timeout": "return {api_version=2, runtime={engine={command={'cat'},timeout_ms=999}}}",
        "instruction_budget": "while true do end",
        "memory_budget": "return string.rep('x',32*1024*1024)",
        "module_escape": "return require('escape')",
    }.items():
        yield {"name": name, "source": source, "valid": False}


def bar_cases():
    def configured(value):
        return "return {api_version=2,client={bars={top={right={bar_kind='static',value=" + value + "}}}}}"

    sources = {
        "empty": "{}", "slots": "{bottom={left={bar_kind='tabs'},center={bar_kind='machines'},right={bar_kind='metrics'}},top={}}",
        "dynamic": "{top={right={bar_kind='dynamic',every_ms=100,render=function()end}}}",
        "command": "{sidebar_footer={{bar_kind='command',command={'echo',''},timeout_ms=100,render=function()end},{bar_kind='metrics'},{bar_kind='machines'}}}",
    }
    for name, source in sources.items():
        yield {"name": "bar_source_" + name, "source": "return {api_version=2,client={bars=" + source + "}}"}
    valid = {
        "text": "'café'", "nil": "nil", "empty": "{}", "nested": "{{{{'deep'}}}}",
        "legacy": "{{text='text',icon='app-editor',fg='PANEL-BG',bg='255',bold=true,italic=false,faint=true,underline=true,strikethrough=false},{icon='cpu'}}",
        "color": "{{ui='label',fg='#f_f_ff',bg='DEFAULT'},{ui='label',fg=0,bg=255}}",
        "inline": "{{ui='label',text='label',tone='accent',priority=0.5},{ui='icon',name='cpu',glyph='😀'},{ui='mark',name='claude'},{ui='meter',value=2,marker=-1,label='CPU',text='50%'},{ui='sparkline',values={1,2,3},max=-1},{ui='badge',text='new',tone='warning'},{ui='clock'},{ui='metric',name='battery'},{ui='machines'}}",
        "tooltip": "{ui='group',mark='telar',icon='cpu',url='https://',on_click='new-tab','child',{ui='label',text='nested'},tooltip={{ui='heading',text='Heading'},{ui='text',text='Text'},{ui='meter_row',label='Use',detail='Half',value=0.5},{ui='kv',key='Key',value='Value'},{ui='divider'}}}",
        "long_text": "string.rep('x',32769)",
    }
    for name, value in valid.items():
        notices = ["bars.max_bar_text_bytes"] if name == "long_text" else []
        yield {"name": "bar_component_" + name, "source": configured(value), "notices": notices}
    yield {"name": "bar_sparkline_tail", "source": "local v={'ignored'};for i=2,121 do v[i]=i end;" + configured("{ui='sparkline',values=v}"), "notices": ["bars.max_node_samples"]}
    yield {"name": "bar_sparkline_limit", "source": configured("(function()local v={};for i=1,120 do v[i]=i end;return {{ui='sparkline',values=v},{ui='sparkline',values=v},{ui='sparkline',values=v}} end)()"), "notices": ["bars.max_samples"]}
    for name, tail, valid_tail in [
        ("dropped_action", "{ui='group',priority=0,on_click='invalid'}", True),
        ("dropped_text", "{ui='label',priority=0,text='bad\\n'}", True),
        ("typed_dropped", "{ui='label',priority=0,text=false}", False),
        ("kept_action", "{ui='group',priority=100,on_click='invalid'}", False),
    ]:
        prefix = "local v={};for i=1,254 do v[i]={ui='label',priority=50,text='kept'} end;v[255]=" + tail + ";"
        yield {"name": "bar_" + name, "source": prefix + configured("v"), "valid": valid_tail, "notices": ["bars.max_bar_nodes"] if valid_tail else []}
    yield {"name": "bar_action_limit", "source": "local c={};for i=1,33 do c[i]=false end;" + configured("{ui='group',on_click={kind='command-tab',command=c}}"), "notices": ["command_tab.max_arguments"]}
    yield {"name": "bar_nested_action_limit", "source": "local c={};for i=1,33 do c[i]=false end;" + configured("{ui='group',on_click={kind='command-tab',command=c},{ui='label',text='invalid\\n'}}"), "notices": ["command_tab.max_arguments"]}
    yield {"name": "bar_demand_actions", "source": "local v={};for i=1,65 do v[i]={ui='group',on_click='new-tab'} end;" + configured("v"), "notices": ["bars.max_bar_nodes", "bars.max_bar_actions"]}
    for name, bars in {
        "table": "false", "field": "{unknown=true}", "bottom_empty": "{bottom={}}",
        "bottom_double": "{bottom={left={bar_kind='tabs'},right={bar_kind='tabs'}}}",
        "bottom_field": "{bottom={left={bar_kind='tabs'},extra=true}}", "top_tabs": "{top={right={bar_kind='tabs'}}}",
        "top_field": "{top={left={bar_kind='metrics'}}}", "footer_tabs": "{sidebar_footer={{bar_kind='tabs'}}}",
        "footer_count": "{sidebar_footer={{bar_kind='metrics'},{bar_kind='metrics'},{bar_kind='metrics'},{bar_kind='metrics'}}}",
        "footer_map": "{sidebar_footer={extra=true}}", "source_kind": "{top={right={bar_kind='unknown'}}}",
        "source_field": "{top={right={bar_kind='metrics',extra=true}}}", "source_type": "{top={right=false}}",
        "render": "{top={right={bar_kind='dynamic',render=false}}}",
        "interval": "{top={right={bar_kind='dynamic',render=function()end,every_ms=3600001}}}",
    }.items():
        yield {"name": "bar_invalid_" + name, "source": "return {api_version=2,client={bars=" + bars + "}}", "valid": False}
    for name, value in {
        "type": "false", "map": "{extra=true}", "depth": "{{{{{'deep'}}}}}", "kind": "{ui='unknown'}",
        "field": "{ui='label',extra=true}", "text": "{ui='label',text='bad\\n'}", "utf8": "string.char(255)",
        "tone": "{ui='label',tone='error'}", "priority": "{ui='label',priority=101}",
        "priority_string": "{ui='label',priority='50'}", "priority_nan": "{ui='label',priority=0/0}",
        "icon_missing": "{ui='icon'}", "icon_unknown": "{ui='icon',name='unknown'}",
        "glyph": "{ui='icon',glyph=string.rep('x',17)}", "mark": "{ui='mark',name='cursor'}",
        "metric": "{ui='metric',name='disk'}", "meter_infinite": "{ui='meter',value=math.huge}",
        "sparkline_type": "{ui='sparkline',values={1,'2'}}", "sparkline_negative": "{ui='sparkline',values={-1}}",
        "clock": "{ui='clock',format=string.rep('x',33)}", "color": "{ui='label',fg=256}",
        "style": "{ui='label',bold=1}", "block": "{ui='heading',text='Heading'}",
        "nested_group": "{ui='group',{ui='group'}}", "tooltip_group": "{ui='group',tooltip={ui='group'}}",
        "tooltip_button": "{ui='group',tooltip={ui='button',text='Go',url='https://example.com'}}",
        "url_scheme": "{ui='group',url='file:///tmp'}", "url_space": "{ui='group',url='https://example.com/a b'}",
        "url_size": "{ui='group',url='https://'..string.rep('x',1017)}",
        "action_function": "{ui='group',on_click=function()end}", "action_unknown": "{ui='group',on_click='unknown'}",
        "group_map": "{ui='group',[0]='zero'}",
    }.items():
        yield {"name": "bar_invalid_component_" + name, "source": configured(value), "valid": False}
    yield {"name": "bar_unused_profile", "source": "return {api_version=2,profiles={unused={client={bars={bottom={}}}}}}", "valid": False}
    commands = "local function bindings(n,shared) local b={};for i=1,n do b[i]={keys={'x'},prefixed=false,action={kind='command-tab',command={string.rep('x',4090)..(shared and '000000' or string.format('%06d',i))}}} end;return b end;"
    yield {"name": "bar_command_pool", "source": commands + "return {api_version=2,client={keybindings=bindings(21,false)}}", "notices": ["config.command_tab_bytes"]}
    yield {"name": "bar_command_deduplication", "source": commands + "return {api_version=2,client={keybindings=bindings(256,true)}}", "forbidden_notices": ["config.command_tab_bytes"]}
    saturated_group = "{ui='group',on_click={kind='command-tab',command={string.rep('y',4096)}},{ui='label',text='invalid\\n'}}"
    yield {"name": "bar_command_pool_children", "source": commands + "return {api_version=2,client={keybindings=bindings(21,false),bars={top={right={bar_kind='static',value=" + saturated_group + "}}}}}", "notices": ["config.command_tab_bytes"]}
    yield {"name": "bar_command_pool_profile", "source": commands + "return {api_version=2,client={keybindings=bindings(19,false)},profiles={selected={client={bars={top={right={bar_kind='static',value=" + saturated_group + "}}}}}}}", "arguments": ["--profile", "selected"], "notices": ["config.command_tab_bytes"]}
    yield {"name": "bar_command_pool_unused", "source": commands + "return {api_version=2,profiles={unused={client={keybindings=bindings(21,false)}}}}", "forbidden_notices": ["config.command_tab_bytes"]}


def definition_cases():
    panel = "{source={bar_kind='dynamic',render=function()end}}"
    pick = "{items={'one'},on_select={'echo','{}'}}"

    def configured(section, value):
        return "return {api_version=2,client={" + section + "={sample=" + value + "}}}"

    valid_panels = {
        "dynamic": panel,
        "command": "{title='',width='720',source={bar_kind='command',command={'echo',''},every_ms=3600000,timeout_ms=10000,render=function()end}}",
        "ignored": "{panel_kind=false,mark=42,icon={},refresh='yes',width=240,source={bar_kind='dynamic',every_ms=100,render=function()end}}",
        "heading": "{mark='telar',icon='PROVIDER-CLAUDE',title='café',source={bar_kind='dynamic',render=function()end}}",
    }
    for name, value in valid_panels.items():
        yield {"name": "definition_panel_" + name, "source": configured("panels", value)}
    valid_picks = {
        "static": pick,
        "empty": "{items={},on_select={'echo','{}',''}}",
        "command": "{command={'echo',''},on_select={'echo','{}'},timeout_ms='60000',refresh=true}",
        "parser": "{pick_kind=false,command={'echo'},items=function()end,on_select={'echo','{}'},timeout_ms=100}",
        "values": "{items={{label='café',value='a\\tb',detail='value',selected=true,swatch={'#ff0000','#00aA00','#0000ff'}}},on_select={'echo','{}'}}",
        "fitted": "{items={{label=string.rep('x',129),value='kept',detail=string.rep('y',129)}},on_select={'echo','{}'}}",
        "oversized": "{items={{label='bad\\n',value=string.rep('x',513)}},on_select={'echo','{}'}}",
    }
    for name, value in valid_picks.items():
        notices = {"fitted": ["picks.max_label_bytes", "picks.max_detail_bytes"], "oversized": ["picks.max_value_bytes"]}.get(name, [])
        yield {"name": "definition_pick_" + name, "source": configured("picks", value), "notices": notices}
    for section, value, notice in [("panels", panel, "panels.max_panels"), ("picks", pick, "picks.max_picks")]:
        source = "local d={};for i=1,16 do d[string.format('a%02d',i)]=" + value + " end;d['z invalid']=false;return {api_version=2,client={" + section + "=d}}"
        yield {"name": "definition_" + section + "_limit", "source": source, "notices": [notice]}
        yield {"name": "definition_" + section + "_sorted_limit", "source": source.replace("'z invalid'", "'0 invalid'"), "valid": False}
        yield {"name": "definition_" + section + "_title_fit", "source": configured(section, value.replace("{", "{title=string.rep('x',128)..'\\n',", 1)), "notices": ["panels.title_bytes"]}
        yield {"name": "definition_" + section + "_numeric_key", "source": "return {api_version=2,client={" + section + "={[1]=" + value + "}}}", "valid": False}
        yield {"name": "definition_" + section + "_long_name", "source": "return {api_version=2,client={" + section + "={[string.rep('x',33)]=" + value + "}}}", "valid": False}
    yield {"name": "definition_pick_item_limit", "source": "local items={};for i=1,4096 do items[i]='x' end;items[4097]='\\n';return {api_version=2,client={picks={sample={items=items,on_select={'echo','{}'}}}}}", "notices": ["picks.max_items"]}
    yield {"name": "definition_pick_text_limit", "source": "local items={};for i=1,600 do items[i]={label='a',value=string.rep('b',512)} end;items[601]='\\n';return {api_version=2,client={picks={sample={items=items,on_select={'echo','{}'}}}}}", "notices": ["picks.max_text_bytes"]}
    invalid_panels = {
        "unknown": "{extra=true}", "missing_source": "{}", "static": "{source={bar_kind='static',value='text'}}",
        "width": "{width=721,source={bar_kind='dynamic',render=function()end}}",
        "width_fraction": "{width=240.5,source={bar_kind='dynamic',render=function()end}}",
        "mark": "{mark='cursor',source={bar_kind='dynamic',render=function()end}}",
        "icon": "{icon='unknown',source={bar_kind='dynamic',render=function()end}}",
        "title": "{title='a\\n',source={bar_kind='dynamic',render=function()end}}",
        "render": "{source={bar_kind='dynamic',render=false}}",
        "interval": "{source={bar_kind='dynamic',every_ms=99,render=function()end}}",
        "command_timeout": "{source={bar_kind='command',command={'echo'},timeout_ms=10001}}",
        "source_field": "{source={bar_kind='dynamic',render=function()end,extra=true}}",
    }
    for name, value in invalid_panels.items():
        yield {"name": "definition_panel_" + name, "source": configured("panels", value), "valid": False}
    invalid_picks = {
        "missing": "{}", "unknown": "{extra=true}", "items_function": "{items=function()end,on_select={'echo','{}'}}",
        "command_items": "{command={'echo'},items={},on_select={'echo','{}'}}",
        "marker": "{items={},on_select={'echo','prefix{}'}}", "program_marker": "{items={},on_select={'{}'}}",
        "refresh": "{items={},on_select={'echo','{}'},refresh='yes'}", "timeout": "{items={},on_select={'echo','{}'},timeout_ms=60001}",
    }
    for name, value in invalid_picks.items():
        yield {"name": "definition_pick_" + name, "source": configured("picks", value), "valid": False}
    for name, item in {
        "empty_label": "''", "empty_value": "{label='a',value=''}", "value_control": "{label='a',value='a\\n'}",
        "label_control": "{label='a\\t'}", "detail_control": "{label='a',detail='a\\t'}",
        "invalid_utf8": "string.char(255)", "value_type": "{label='a',value=1}", "selected": "{label='a',selected=1}",
        "swatch_count": "{label='a',swatch={'#ffffff'}}", "swatch_value": "{label='a',swatch={'#ffffff','#ffffff','#ff_fff'}}",
        "field": "{label='a',extra=true}",
    }.items():
        yield {"name": "definition_item_" + name, "source": configured("picks", "{items={" + item + "},on_select={'echo','{}'}}"), "valid": False}
    for name, command in {
        "empty": "{}", "program": "{''}", "nul": "{'a\\0b'}", "bytes": "{string.rep('x',4097)}",
        "type": "{'echo',1}", "map": "{'echo',extra=true}", "count": "(function()local a={};for i=1,33 do a[i]='x' end;return a end)()",
    }.items():
        yield {"name": "definition_command_" + name, "source": configured("picks", "{command=" + command + ",on_select={'echo','{}'}}"), "valid": False}
    yield {"name": "definition_unused_profile", "source": "return {api_version=2,profiles={unused={client={panels={invalid={}}}}}}", "valid": False}


def binding_cases():
    def configured(action, extra=""):
        return "return {api_version=2,client={keybindings={{keys={'cmd+x'},prefixed=false,action=" + action + extra + "}}}}"

    valid_actions = {
        "builtin": "'new-tab'", "index": "'select-tab-255'", "index_separator": "'select-workspace-1__0'",
        "function": "function() return 'close-pane' end", "expression": "function() return 'text' end,expression=true",
        "direction": "{kind='navigate-pane',direction='left'}", "split": "{kind='split-pane',direction='vertical'}",
        "offset": "{kind='select-tab-offset',offset=-128}", "table_index": "{kind='select-tab',index=256}",
        "numeric_string": "{kind='select-workspace',index='256'}", "plugin": "{kind='plugin',plugin='',action=''}",
        "notification": "{kind='notification',title='Ready',body='Done',duration_ms=500,pane_id=1}",
        "command": "{kind='command-tab',command={'echo','value'},label=false}",
    }
    for name, action in valid_actions.items():
        yield {"name": "binding_" + name, "source": configured(action)}
    yield {"name": "binding_ignored_keys", "source": "return {api_version=2,client={keybindings={ignored=false,{prefixed=false,keys={'x',ignored=true},action='new-tab'}}}}"}
    yield {"name": "binding_limit", "source": "local b={};for i=1,256 do b[i]={keys={'x'},prefixed=false,action='new-tab'} end;b[257]=false;return {api_version=2,client={keybindings=b}}", "notices": ["config.max_bindings"]}
    yield {"name": "binding_command_limit", "source": "local c={};for i=1,33 do c[i]=false end;return {api_version=2,client={keybindings={{keys={'x'},prefixed=false,action={kind='command-tab',command=c}}}}}", "notices": ["command_tab.max_arguments"]}
    yield {"name": "binding_command_bytes", "source": configured("{kind='command-tab',command={string.rep('x',4097)}}"), "notices": ["command_tab.max_command_bytes"]}
    yield {"name": "binding_notification_fit", "source": configured("{kind='notification',title=string.rep('x',97),body=string.rep('y',513)}"), "notices": ["notifications.max_title_bytes", "notifications.max_message_bytes"]}
    yield {"name": "binding_inherited_panel", "source": "return {api_version=2,client={panels={sample={source={bar_kind='dynamic',render=function()end}}}},profiles={unused={client={keybindings={{keys={'x'},prefixed=false,action={kind='open-panel',panel='sample'}}}}}}}"}
    for name, keys, prefixed in [
        ("defaults", "{'x'}", False), ("default_override", "{'x'}", True),
        ("prefix_override", "{'CONTROL+B'}", False), ("shift_override", "{'shift+n'}", True),
        ("long_override", "{'ctrl+b','N','x'}", False),
    ]:
        source = "local b={};for i=1,220 do b[i]={keys=" + keys + ",prefixed=" + str(prefixed).lower() + ",action='new-tab'} end;return {api_version=2,client={keybindings=b}}"
        yield {"name": "binding_keymap_" + name, "source": source, "notices": [] if name == "prefix_override" else ["config.max_bindings"]}
    for prefix in ["ctrl+b", "cmd+p"]:
        source = "local b={};for i=1,220 do b[i]={keys={'CTRL+B'},prefixed=false,action='new-tab'} end;return {api_version=2,client={keybindings=b},profiles={selected={client={prefix='" + prefix + "'}}}}"
        yield {"name": "binding_keymap_profile_" + prefix, "source": source, "arguments": ["--profile", "selected"]}
    yield {"name": "binding_keymap_unused", "source": "local b={};for i=1,256 do b[i]={keys={'x'},prefixed=false,action='new-tab'} end;return {api_version=2,profiles={unused={client={keybindings=b}}}}", "forbidden_notices": ["config.max_bindings"]}
    invalid_actions = {
        "unknown": "'made-up'", "index_zero": "'select-tab-0'", "index_overflow": "'select-tab-256'",
        "index_leading_separator": "'select-tab-_1'", "index_sign": "'select-tab-+1'",
        "action_type": "false", "kind_type": "{kind=1}", "extra_field": "{kind='new-tab',extra=true}",
        "direction_missing": "{kind='focus-pane'}", "direction_invalid": "{kind='resize-sidebar',direction='up'}",
        "offset_range": "{kind='select-tab-offset',offset=128}", "index_missing": "{kind='select-tab'}",
        "index_table_overflow": "{kind='select-tab',index=257}", "plugin_field": "{kind='plugin',plugin='test'}",
        "panel_missing": "{kind='open-panel',panel='missing'}", "pick_missing": "{kind='pick',pick='missing'}",
        "command_empty": "{kind='command-tab',command={}}", "argument_empty": "{kind='command-tab',command={'echo',''}}",
        "command_nul": "{kind='command-tab',command={'echo','a\\0b'}}", "command_array": "{kind='command-tab',command={'echo',extra='x'}}",
        "command_label": "{kind='command-tab',command={'echo'},label=string.rep('x',33)}",
        "notification_title": "{kind='notification',title=''}", "notification_control": "{kind='notification',title='line\\n'}",
        "notification_targets": "{kind='notification',title='Test',pane_id=1,tab_id=2}",
        "notification_timeout": "{kind='notification',title='Test',duration_ms=499}",
        "notification_target": "{kind='notification',title='Test',workspace_id=0}",
        "notification_level": "{kind='notification',title='Test',level='error'}",
        "expression_action": "'new-tab',expression=true", "expression_type": "'new-tab',expression=1",
    }
    for name, action in invalid_actions.items():
        yield {"name": "binding_" + name, "source": configured(action), "valid": False}
    for name, binding in {
        "prefix_missing": "{keys={'x'},action='new-tab'}", "prefix_type": "{keys={'x'},prefixed=1,action='new-tab'}",
        "keys_empty": "{keys={},prefixed=false,action='new-tab'}", "keys_long": "{keys={'a','b','c','d','e'},prefixed=true,action='new-tab'}",
        "keys_type": "{keys={1},prefixed=false,action='new-tab'}", "key_invalid": "{keys={'shift+1'},prefixed=false,action='new-tab'}",
    }.items():
        yield {"name": "binding_" + name, "source": "return {api_version=2,client={keybindings={" + binding + "}}}", "valid": False}


def client_cases():
    yield {"name": "client_options", "source": "return {api_version=2,client={prefix='ctrl+space',pane_gaps=false,editor='nvim',window_title='',sidebar={visible=false,renderer=42},sound={enabled=false,ready=true,needs_input=false},notifications={delivery='system'},input={sequence_timeout_ms='10000',escape_timeout_ms=false},history={show_agent_commands=true,enter='run',match='fts'},icons=false}}"}
    yield {"name": "client_profile", "source": "return {api_version=2,profiles={unused={client={window_title=string.rep('x',128),editor=string.rep('x',4096),input={sequence_timeout_ms=10},notifications={delivery='terminal'}}}}}"}
    for index, prefix in enumerate(['CTRL+b', 'command+shift+P', 'alt+shift+x', 'shift+space', 'ctrl+shift+up', 'shift+tab', 'alt+é', 'cmd+shift+好', 'plus', 'page-down', 'backtab']):
        yield {"name": f"client_prefix_valid_{index}", "source": "return {api_version=2,client={prefix='" + prefix + "'}}"}
    for index, prefix in enumerate(['', '+x', 'x+', 'x+ctrl', 'ctrl+control+b', 'cmd+super+x', 'shift', 'ctrl+shift+a', 'shift+é', 'shift+plus', 'shift+1', 'unknown', 'ctrl++', 'alt+alt+x']):
        yield {"name": f"client_prefix_invalid_{index}", "source": "return {api_version=2,client={prefix='" + prefix + "'}}", "valid": False}
    invalid = {
        "table": "false", "unknown": "{unknown=true}", "prefix_type": "{prefix=1}",
        "prefix_utf8": "{prefix=string.char(255)}", "gaps": "{pane_gaps=1}",
        "editor_empty": "{editor=''}", "editor_length": "{editor=string.rep('x',4097)}",
        "editor_control": "{editor='nvim\\n'}", "title_length": "{window_title=string.rep('x',129)}",
        "title_control": "{window_title='a'..string.char(127)}", "title_utf8": "{window_title=string.char(255)}",
        "sidebar": "{sidebar={visible=1}}", "sidebar_field": "{sidebar={width=20}}",
        "sound": "{sound={ready='yes'}}", "sound_field": "{sound={other=true}}",
        "notifications": "{notifications={delivery='invalid'}}", "notifications_field": "{notifications={unknown=true}}",
        "notifications_terminal_field": "{notifications={terminal=true}}",
        "input": "{input={sequence_timeout_ms=9}}", "input_fraction": "{input={sequence_timeout_ms=10.5}}",
        "input_field": "{input={unknown=1}}", "history": "{history={enter='execute'}}",
        "history_match": "{history={match='regex'}}", "history_bool": "{history={show_agent_commands=1}}",
    }
    for name, value in invalid.items():
        yield {"name": "client_" + name, "source": "return {api_version=2,client=" + value + "}", "valid": False}
    yield {"name": "client_unused_profile", "source": "return {api_version=2,profiles={unused={client={sound={ready=1}}}}}", "valid": False}


def appearance_cases():
    gui = "{font={family='Iosevka Term',style='',size=6,line_height=0.75,letter_spacing=-5,thicken=false,thicken_strength=255}, cursor={style='hollow',blink=true,blink_interval_ms=5000},window={background_opacity=0,background_blur=true,titlebar=false,padding={x=256,y=0}},chrome={scale=2},sidebar={width=800},max_fps=240}"
    yield {"name": "appearance_gui_bounds", "source": "return {api_version=2,gui=" + gui + "}"}
    yield {"name": "appearance_gui_profile", "source": "return {api_version=2,gui={font={size=96},max_fps=30},profiles={unused={gui=" + gui + "}}}"}
    yield {"name": "appearance_theme", "source": "local palette={};for i=1,16 do palette[i]='#a0B1c2' end; return {api_version=2,theme={base='KaNaGaWa_DRAGON',colors={text='default',accent='#123456'},terminal={palette=palette,cursor_color='#ff0000'},syntax={keyword={fg='default',bold=true,italic=false},func='#010203'}},client={appearance={light='mocha',dark={colors={surface0='#000000'}}}}}"}
    yield {"name": "appearance_theme_alias", "source": "return {api_version=2,client={theme='TOKYONIGHT'},profiles={unused={theme='pierre-dark-soft'}}}"}
    invalid_gui = {
        "table": "false", "unknown": "{unknown=true}", "old_theme": "{theme='vesper'}",
        "font_size": "{font={size=5.99}}", "font_infinite": "{font={size=math.huge}}",
        "font_nan": "{font={size=0/0}}", "font_string": "{font={size='12'}}",
        "font_family": "{font={family=string.rep('x',257)}}", "font_nul": "{font={style='a\\0b'}}",
        "font_utf8": "{font={family=string.char(255)}}", "thicken": "{font={thicken=1}}",
        "thicken_fraction": "{font={thicken_strength=1.5}}", "cursor_style": "{cursor={style='Block'}}",
        "cursor_interval": "{cursor={blink_interval_ms=99}}", "window_opacity": "{window={background_opacity=1.1}}",
        "blur_fraction": "{window={background_blur=1.5}}", "padding": "{window={padding={x=-1}}}",
        "chrome": "{chrome={scale=0.49}}", "sidebar": "{sidebar={width=219}}",
        "fps": "{max_fps=29}", "fps_fraction": "{max_fps=60.5}", "unused_profile": "{max_fps=241}",
    }
    for name, value in invalid_gui.items():
        body = "profiles={unused={gui=" + value + "}}" if name == "unused_profile" else "gui=" + value
        yield {"name": "appearance_gui_" + name, "source": "return {api_version=2," + body + "}", "valid": False}
    invalid_themes = {
        "name": "theme='missing'", "duplicate": "theme='shade',client={theme='vesper'}",
        "field": "theme={unknown=true}", "color_field": "theme={colors={missing='#ffffff'}}",
        "color": "theme={colors={text='#gggggg'}}", "terminal_default": "theme={terminal={background='default'}}",
        "palette": "theme={terminal={palette={'#ffffff'}}}", "syntax_role": "theme={syntax={unknown='default'}}",
        "syntax_style": "theme={syntax={comment={underline=true}}}", "syntax_boolean": "theme={syntax={comment={italic=1}}}",
        "appearance": "client={appearance={light='missing'}}", "profile": "profiles={unused={theme=false}}",
    }
    for name, body in invalid_themes.items():
        yield {"name": "appearance_theme_" + name, "source": "return {api_version=2," + body + "}", "valid": False}


def check_case(binary, case):
    with tempfile.TemporaryDirectory(prefix="telar-config-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update({"HOME": str(root), "XDG_CONFIG_HOME": str(root / "config"),
                            "XDG_DATA_HOME": str(root / "data"), "XDG_STATE_HOME": str(root / "state"),
                            "XDG_CACHE_HOME": str(root / "cache")})
        configuration = root / "config/telar/config.lua"
        configuration.parent.mkdir(parents=True)
        configuration.write_text(case["source"])
        (configuration.parent / "local.lua").write_text(case.get("module", "return {}"))
        (root / "outside.lua").write_text("return {api_version=2}")
        (configuration.parent / "escape.lua").symlink_to(root / "outside.lua")
        socket = root / "runtime.sock"
        command = [str(binary), "server", "--socket", str(socket)]
        if case.get("development"):
            environment["TELAR_DEVELOPMENT_CONFIG"] = str(configuration)
        elif not case.get("implicit"):
            selected_path = configuration if case.get("background") else configuration.relative_to(root)
            command.extend(["--config", str(selected_path)])
        command.extend(case.get("arguments", []))
        if case.get("background"):
            command.append("--background")
        with (root / "runtime.log").open("w+") as log:
            process = subprocess.Popen(command, cwd=root, env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 12
                while not socket.exists() and time.monotonic() < deadline:
                    if process.poll() is not None and not case.get("background"):
                        break
                    if process.poll() not in (None, 0):
                        break
                    time.sleep(0.01)
                if case.get("valid", True):
                    if not socket.exists():
                        log.seek(0)
                        raise AssertionError(f"{binary}/{case['name']}: runtime did not start: {log.read()}")
                    expected_history = configuration.parent / case["history"] if "history" in case else root / "data/telar/history.db"
                    assert expected_history.exists(), f"{case['name']}: missing history at {expected_history}"
                    log.seek(0)
                    errors = log.read()
                    for notice in case.get("notices", []):
                        assert notice in errors, f"{case['name']}: missing notice {notice}"
                    for notice in case.get("forbidden_notices", []):
                        assert notice not in errors, f"{case['name']}: unexpected notice {notice}"
                    prefix = "telar config: limit reached, the excess was left out: "
                    actual_notices = [line.removeprefix(prefix) for line in errors.splitlines() if line.startswith(prefix)]
                    return {"started": True, "history": str(expected_history.relative_to(root)), "notices": actual_notices}
                assert not socket.exists(), f"{case['name']}: invalid configuration was accepted"
                assert process.wait(timeout=3) == 1, f"{case['name']}: expected exit status 1"
                return {"started": False, "exit_status": 1}
            finally:
                if socket.exists():
                    subprocess.run([str(binary), "server", "stop", "--socket", str(socket)], env=environment,
                                   capture_output=True, check=True, timeout=12)
                    deadline = time.monotonic() + 10
                    while socket.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    assert not socket.exists(), "Runtime did not remove its socket on shutdown"
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description="Verify startup configuration against the frozen Zig runtime")
    for name in ("zig", "cpp", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--prefix", default="", help="Run only cases with this name prefix")
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp")}
    report = {"measured_at": datetime.now(timezone.utc).isoformat(),
              "binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in binaries.items()},
              "cases": {}}
    for case in cases():
        if not case["name"].startswith(arguments.prefix):
            continue
        try:
            results = {name: check_case(binary, case) for name, binary in binaries.items()}
            assert results["zig"] == results["cpp"], f"{case['name']}: {results}"
        except Exception as error:
            report["failure"] = {"case": case["name"], "message": str(error)}
            arguments.output.write_text(json.dumps(report, indent=2) + "\n")
            raise
        report["cases"][case["name"]] = results
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"{case['name']}: equal", flush=True)


if __name__ == "__main__":
    main()
