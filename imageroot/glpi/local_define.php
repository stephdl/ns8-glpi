<?php

// Only Traefik can reach the pod: its port is published on 127.0.0.1 of the node.
define('GLPI_TRUSTED_REVERSE_PROXIES', ['REMOTE_ADDR']);
define('GLPI_REVERSE_PROXY_HEADERS', ['X-Forwarded-For', 'X-Forwarded-Proto', 'X-Forwarded-Host', 'X-Forwarded-Port']);
