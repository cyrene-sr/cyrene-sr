; Protobuf field ids
; query_dispatch rsp
dispatch_region_list_field_id equ 4
region_server_name_field_id equ 1
region_dispatch_url_field_id equ 3
region_env_field_id equ 4
region_title_field_id equ 5

; query_gateway rsp
gateserver_ip_field_id equ 5
gateserver_port_field_id equ 14
gateserver_lua_url_field_id equ 1
gateserver_ex_resource_url_field_id equ 6
gateserver_asset_bundle_url_field_id equ 7
gateserver_enable_version_update_field_id equ 15
gateserver_enable_design_data_version_update_field_id equ 8
gateserver_use_tcp_field_id equ 821

macro encode_region_pb encode_buf, region_name, dispatch_url, region_env, region_title {
  postpone
  \{
    macro_region_name#region_name db `region_name
    macro_region_name_len#region_name = $ - macro_region_name#region_name
    macro_dispatch_url#region_name db dispatch_url
    macro_dispatch_url_len#region_name = $ - macro_dispatch_url#region_name
    macro_region_env#region_name db region_env
    macro_region_env_len#region_name = $ - macro_region_env#region_name
    macro_region_title#region_name db region_title
    macro_region_title_len#region_name = $ - macro_region_title#region_name
  \}

  mov rsi, encode_buf
  pb_write_bytes rsi, region_server_name_field_id, macro_region_name\#region_name, macro_region_name_len\#region_name
  pb_write_bytes rsi, region_dispatch_url_field_id, macro_dispatch_url\#region_name, macro_dispatch_url_len\#region_name
  pb_write_bytes rsi, region_env_field_id, macro_region_env\#region_name, macro_region_env_len\#region_name
  pb_write_bytes rsi, region_title_field_id, macro_region_title\#region_name, macro_region_title_len\#region_name
}
