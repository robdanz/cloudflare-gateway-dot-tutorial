resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@53
round_robin_upstreams: 1
upstream_recursive_servers:
  - address_data: ${DOT_IP}
    tls_auth_name: "${DOT_HOSTNAME}"
    tls_port: ${DOT_PORT}
