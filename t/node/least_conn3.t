#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

repeat_each(2);
log_level('info');
no_root_location();
no_shuffle();

run_tests();

__DATA__

=== TEST 1: keep in-flight conn count across balancer recreation on scaling
--- config
    location /t {
        content_by_lua_block {
            local least_conn = require("apisix.balancer.least_conn")
            -- resource_key is stable across scaling, so both pickers share the
            -- same connection count table
            local up = {resource_key = "/upstreams/lc-scale"}

            -- 2 nodes serving long-lived connections
            local nodes = {["127.0.0.1:1980"] = 1, ["127.0.0.1:1981"] = 1}
            local p1 = least_conn.new(nodes, up)

            -- establish 4 in-flight connections (get without after_balance)
            local ctx = {}
            local held = {}
            for _ = 1, 4 do
                held[#held + 1] = p1.get(ctx)
            end

            -- scale out: add a third node, the picker is recreated
            local scaled = {["127.0.0.1:1980"] = 1, ["127.0.0.1:1981"] = 1,
                            ["127.0.0.1:1982"] = 1}
            local p2 = least_conn.new(scaled, up)

            -- the freshly added node has no connection, so it must be picked first
            for _ = 1, 2 do
                local s = p2.get(ctx)
                held[#held + 1] = s
                ngx.say(s)
            end

            -- release everything so repeated runs start from a clean state
            for _, s in ipairs(held) do
                ctx.balancer_server = s
                p2.after_balance(ctx, false)
            end
        }
    }
--- request
GET /t
--- response_body
127.0.0.1:1982
127.0.0.1:1982



=== TEST 2: scale down drops the removed node, remaining nodes balance
--- config
    location /t {
        content_by_lua_block {
            local least_conn = require("apisix.balancer.least_conn")
            local up = {resource_key = "/upstreams/lc-scale-down"}

            local nodes = {["127.0.0.1:1980"] = 1, ["127.0.0.1:1981"] = 1}
            local p1 = least_conn.new(nodes, up)

            local ctx = {}
            -- fully complete two requests, one per node
            for _ = 1, 2 do
                local s = p1.get(ctx)
                ctx.balancer_server = s
                p1.after_balance(ctx, false)
            end

            -- scale down to a single remaining node, picker recreated
            local scaled = {["127.0.0.1:1981"] = 1}
            local p2 = least_conn.new(scaled, up)

            local s = p2.get(ctx)
            ctx.balancer_server = s
            p2.after_balance(ctx, false)
            ngx.say(s)
        }
    }
--- request
GET /t
--- response_body
127.0.0.1:1981
