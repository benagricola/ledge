SHELL := /bin/bash # Cheat by using bash :)

OPENRESTY_PREFIX    = /usr/local/openresty-debug

TEST_FILE          ?= t
SENTINEL_TEST_FILE ?= $(TEST_FILE)/sentinel

REDIS_CMD           ?= redis-server
SENTINEL_CMD        ?= $(REDIS_CMD) --sentinel
SQUID_CMD           ?= squid

SQUID_PID           = /squid.pid
SQUID_PREFIX        = /tmp/squid

REDIS_SOCK          = /redis.sock
REDIS_PID           = /redis.pid
REDIS_LOG           = /redis.log
REDIS_PREFIX        = /tmp/redis-

# Overrideable ledge test variables
TEST_LEDGE_REDIS_PORTS              ?= 6379 6380
TEST_LEDGE_REDIS_DATABASE           ?= 1

REDIS_FIRST_PORT                    := $(firstword $(TEST_LEDGE_REDIS_PORTS))
REDIS_SLAVE_ARG                     := --slaveof 127.0.0.1 $(REDIS_FIRST_PORT)
REDIS_CLI                           := redis-cli -p $(REDIS_FIRST_PORT) -n $(TEST_LEDGE_REDIS_DATABASE)

# Override ledge socket for running make test on its' own 
# (make test TEST_LEDGE_REDIS_SOCKET=/path/to/sock.sock)
TEST_LEDGE_REDIS_SOCKET             ?= $(REDIS_PREFIX)$(REDIS_FIRST_PORT)$(REDIS_SOCK)

# Overrideable ledge + sentinel test variables
TEST_LEDGE_SENTINEL_PORTS           ?= 6381 6382 6383
TEST_LEDGE_SENTINEL_MASTER_NAME     ?= mymaster
TEST_LEDGE_SENTINEL_PROMOTION_TIME  ?= 20

TEST_LEDGE_SQUID_PORT               ?= 3128

# Command line arguments for ledge tests
TEST_LEDGE_REDIS_VARS     = PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$(PATH) \
TEST_LEDGE_REDIS_SOCKET=unix://$(TEST_LEDGE_REDIS_SOCKET) \
TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) \
TEST_NGINX_NO_SHUFFLE=1

# Command line arguments for ledge tests via squid
TEST_LEDGE_SQUID_VARS     = $(TEST_LEDGE_REDIS_VARS) \
TEST_NGINX_CLIENT_PORT=$(TEST_LEDGE_SQUID_PORT)

# Command line arguments for ledge + sentinel tests
TEST_LEDGE_SENTINEL_VARS  = PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$(PATH) \
TEST_LEDGE_SENTINEL_PORT=$(firstword $(TEST_LEDGE_SENTINEL_PORTS)) \
TEST_LEDGE_SENTINEL_MASTER_NAME=$(TEST_LEDGE_SENTINEL_MASTER_NAME) \
TEST_LEDGE_REDIS_DATABASE=$(TEST_LEDGE_REDIS_DATABASE) \
TEST_NGINX_NO_SHUFFLE=1

# Sentinel configuration can only be set by a config file
define TEST_LEDGE_SENTINEL_CONFIG
sentinel       monitor $(TEST_LEDGE_SENTINEL_MASTER_NAME) 127.0.0.1 $(REDIS_FIRST_PORT) 2
sentinel       down-after-milliseconds $(TEST_LEDGE_SENTINEL_MASTER_NAME) 2000
sentinel       failover-timeout $(TEST_LEDGE_SENTINEL_MASTER_NAME) 10000
sentinel       can-failover $(TEST_LEDGE_SENTINEL_MASTER_NAME) yes
sentinel       parallel-syncs $(TEST_LEDGE_SENTINEL_MASTER_NAME) 5
endef

export TEST_LEDGE_SENTINEL_CONFIG

SENTINEL_CONFIG_FILE = /tmp/sentinel-test-config

define TEST_LEDGE_SQUID_CONFIG
visible_hostname 'squid'

http_port 3128 accel defaultsite=localhost

acl localhost src 127.0.0.1/32
acl localnet src 127.0.0.0/24
http_access allow localnet
http_access allow localhost
http_access deny all

pid_filename $(SQUID_PREFIX)$(SQUID_PID)
access_log $(SQUID_PREFIX)/access.log
cache_log $(SQUID_PREFIX)/cache.log
cache deny all
cache_peer 127.0.0.1 parent 1984 0 no-query originserver name=edge
endef

export TEST_LEDGE_SQUID_CONFIG

SQUID_CONFIG_FILE = /tmp/squid-test-config


PREFIX          ?= /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR     ?= $(PREFIX)/lib/lua/$(LUA_VERSION)
PROVE           ?= prove -I ../test-nginx/lib
INSTALL         ?= install

.PHONY: all install test test_all start_redis_instances stop_redis_instances \
	start_redis_instance stop_redis_instance cleanup_redis_instance flush_db \
	start_squid stop_squid  \
	create_sentinel_config delete_sentinel_config check_ports test_ledge \
	test_sentinel

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/ledge
	$(INSTALL) lib/ledge/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/ledge

test: test_ledge

test_all: start_redis_instances test_ledge start_squid \
	test_revalidation_squid stop_squid test_sentinel \
	stop_redis_instances

start_redis_instances: check_ports create_sentinel_config
	@$(foreach port,$(TEST_LEDGE_REDIS_PORTS), \
		[[ "$(port)" != "$(REDIS_FIRST_PORT)" ]] && \
			SLAVE="$(REDIS_SLAVE_ARG)" || \
			SLAVE="" && \
		$(MAKE) start_redis_instance args="$$SLAVE" port=$(port) \
		prefix=$(REDIS_PREFIX)$(port) && \
	) true

	@$(foreach port,$(TEST_LEDGE_SENTINEL_PORTS), \
		$(MAKE) start_redis_instance \
		port=$(port) args="$(SENTINEL_CONFIG_FILE) --sentinel" \
		prefix=$(REDIS_PREFIX)$(port) && \
	) true

stop_redis_instances: delete_sentinel_config 
	-@$(foreach port,$(TEST_LEDGE_REDIS_PORTS) $(TEST_LEDGE_SENTINEL_PORTS), \
		$(MAKE) stop_redis_instance cleanup_redis_instance port=$(port) \
		prefix=$(REDIS_PREFIX)$(port) && \
	) true 2>&1 > /dev/null

start_redis_instance:
	-@echo "Starting redis on port $(port) with args: \"$(args)\""
	-@mkdir -p $(prefix)
	@$(REDIS_CMD) $(args) \
		--pidfile $(prefix)$(REDIS_PID) \
		--bind 127.0.0.1 --port $(port) \
		--unixsocket $(prefix)$(REDIS_SOCK) \
		--unixsocketperm 777 \
		--dir $(prefix) \
		--logfile $(prefix)$(REDIS_LOG) \
		--loglevel debug \
		--daemonize yes

stop_redis_instance:
	-@echo "Stopping redis on port $(port)"
	-@[[ -f "$(prefix)$(REDIS_PID)" ]] && kill -QUIT \
	`cat $(prefix)$(REDIS_PID)` 2>&1 > /dev/null || true

cleanup_redis_instance: stop_redis_instance
	-@echo "Cleaning up redis files in $(prefix)"
	-@rm -rf $(prefix)

flush_db:
	-@echo "Flushing Redis DB"
	@$(REDIS_CLI) flushdb

start_squid: check_ports
	-@echo "Creating $(SQUID_CONFIG_FILE)"
	@echo "$$TEST_LEDGE_SQUID_CONFIG" > $(SQUID_CONFIG_FILE)
	-@echo "Starting squid on port $(TEST_LEDGE_SQUID_PORT) with args: \"$(args)\""
	-@mkdir -p $(SQUID_PREFIX)
	@$(SQUID_CMD) $(args) \
	    -a $(TEST_LEDGE_SQUID_PORT) \
	    -f $(SQUID_CONFIG_FILE) > /dev/null 2>&1

stop_squid:
	-@echo "Stopping squid on port $(TEST_LEDGE_SQUID_PORT)"
	-@$(SQUID_CMD) -f $(SQUID_CONFIG_FILE) -k kill > /dev/null 2>&1
	-@echo "Removing $(SQUID_CONFIG_FILE)"
	@rm -f $(SQUID_CONFIG_FILE)

create_sentinel_config:
	-@echo "Creating $(SENTINEL_CONFIG_FILE)"
	@echo "$$TEST_LEDGE_SENTINEL_CONFIG" > $(SENTINEL_CONFIG_FILE)

delete_sentinel_config:
	-@echo "Removing $(SENTINEL_CONFIG_FILE)"
	@rm -f $(SENTINEL_CONFIG_FILE)

check_ports:
	-@echo "Checking ports $(REDIS_PORTS) $(TEST_LEDGE_SQUID_PORT)"
	@$(foreach port,$(REDIS_PORTS)$(TEST_LEDGE_SQUID_PORT),! lsof -i :$(port) &&) true 2>&1 > /dev/null

test_ledge:
	$(MAKE) flush_db
	$(TEST_LEDGE_REDIS_VARS) $(PROVE) $(TEST_FILE)

test_revalidation_squid: 
	$(MAKE) flush_db
	$(TEST_LEDGE_SQUID_VARS) $(PROVE) $(TEST_FILE)/09-validation.t

test_sentinel: 
	$(MAKE) flush_db
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) $(SENTINEL_TEST_FILE)/01-master_up.t
	$(REDIS_CLI) shutdown
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) $(SENTINEL_TEST_FILE)/02-master_down.t
	sleep $(TEST_LEDGE_SENTINEL_PROMOTION_TIME)
	$(TEST_LEDGE_SENTINEL_VARS) $(PROVE) $(SENTINEL_TEST_FILE)/03-slave_promoted.t
