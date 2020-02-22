-- 
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
-- 
--    http://www.apache.org/licenses/LICENSE-2.0
-- 
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- 

local spanLayer = require("span_layer")
local Util = require('util')
local SegmentRef = require("segment_ref")

local CONTEXT_CARRIER_KEY = 'sw6'

local Span = {
    span_id,
    parent_span_id,
    operation_name,
    tags,
    logs,
    layer = spanLayer.NONE,
    is_entry = false,
    is_exit = false,
    peer,
    start_time,
    end_time,
    error_occurred = false,
    component_id,
    refs,
    is_noop = false,
    -- owner is a TracingContext reference
    owner,
}

-- Due to nesting relationship inside Segment/Span/TracingContext at the runtime,
-- SpanProtocol is created to prepare JSON format serialization.
-- Following SkyWalking official trace protocol v2
-- https://github.com/apache/skywalking-data-collect-protocol/blob/master/language-agent-v2/trace.proto
local SpanProtocol = {
    spanId,
    parentSpanId,
    startTime,
    endTime,
    -- Array of RefProtocol
    refs,
    operationName,
    peer,
    spanType,
    spanLayer,
    componentId,
    isError,
    tags,
    logs,
}

-- Create an entry span. Represent the HTTP incoming request.
-- @param contextCarrier, HTTP request header, which could carry the `sw6` context
function Span:createEntrySpan(operationName, context, parent, contextCarrier)
    local span = self:new(operationName, context, parent)
    span.is_entry = true

    if contextCarrier ~= nil then
        local propagatedContext = contextCarrier[CONTEXT_CARRIER_KEY]
        if propagatedContext ~= nil then
            local ref = SegmentRef:new():fromSW6Value(propagatedContext)
            if ref ~= nil then
                -- If current trace id is generated by the context, in LUA case, mostly are yes
                -- use the ref trace id to override it, in order to keep trace id consistently same.
                context.internal:addRefIfFirst(ref)
                span.refs[#span.refs + 1] = ref
            end
        end
    end

    return span
end

-- Create an exit span. Represent the HTTP outgoing request.
function Span:createExitSpan(operationName, context, parent, peer, contextCarrier)
    local span = self:new(operationName, context, parent)
    span.is_exit = true
    span.peer = peer

    if contextCarrier ~= nil then
        -- if there is contextCarrier container, the Span will inject the value based on the current tracing context
        local injectableRef = SegmentRef:new()
        injectableRef.trace_id = context.trace_id
        injectableRef.segment_id = context.segment_id
        injectableRef.span_id = span.span_id
        -- injectableRef.network_address_id wouldn't be set. Right now, there is no network_address register mechanism
        injectableRef.network_address = '#' .. peer

        local entryServiceInstanceId
        local entryEndpointName
        -- -1 represent the endpoint id doesn't exist, but it is a meaningful value.
        -- Once -1 is here, the entryEndpointName will be ignored.
        local entryEndpointId = -1

        local firstSpan = context.internal.first_span
        if context.internal:hasRef() then
            local firstRef = context.internal:getFirstRef()
            injectableRef.entry_service_instance_id = firstRef.entry_service_instance_id
            entryEndpointName = firstRef.entry_endpoint_name
            entryEndpointId = firstRef.entry_endpoint_id
            entryServiceInstanceId = firstRef.entry_service_instance_id
        else
            injectableRef.entry_service_instance_id = context.service_inst_id
            if firstSpan.is_entry then
                entryEndpointId = 0
                entryEndpointName = firstSpan.operation_name
            end
            entryServiceInstanceId = context.service_inst_id
        end
        
        injectableRef.entry_service_instance_id = entryServiceInstanceId
        injectableRef.parent_service_instance_id = context.service_inst_id
        injectableRef.entry_endpoint_name = entryEndpointName
        injectableRef.entry_endpoint_id = entryEndpointId

        local parentEndpointName
        local parentEndpointId = -1
        
        if firstSpan.is_entry then
            parentEndpointName = firstSpan.operation_name
            parentEndpointId = 0
        end
        injectableRef.parent_endpoint_name = parentEndpointName
        injectableRef.parent_endpoint_id = parentEndpointId

        contextCarrier[CONTEXT_CARRIER_KEY] = injectableRef:serialize()
    end

    return span
end

-- Create an local span. Local span is usually not used. 
-- Typically, only one entry span and one exit span in the Nginx tracing segment.
function Span:createLocalSpan(operationName, context, parent)
    local span = self:new(operationName, context, parent) 
    return span
end

-- Create a default span.
-- Usually, this method wouldn't be called by outside directly.
-- Read newEntrySpan, newExitSpan and newLocalSpan for more details
function Span:new(operationName, context, parent)
    local o = {}
    setmetatable(o, self)
    self.__index = self

    o.operation_name = operationName
    o.span_id = context.internal:nextSpanID()
    
    if parent == nil then
        -- As the root span, the parent span id is -1
        o.parent_span_id = -1
    else
        o.parent_span_id = parent.span_id
    end 

    context.internal:addActive(o)
    o.start_time = Util.timestamp()
    o.refs = {}
    o.owner = context
    o.tags = {}
    o.logs = {}

    return o
end

function Span:newNoOP()
    local o = {}
    setmetatable(o, self)
    self.__index = self

    o.is_noop = true
    return o
end

function SpanProtocol:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self

    return o
end

---- All belowing are instance methods

-- Set start time explicitly
function Span:start(startTime)
    if self.is_noop then
        return self
    end

    self.start_time = startTime

    return self
end

function Span:finishWithDuration(duration)
    if self.is_noop then
        return self
    end

    self:finish(self.start_time + duration)
    
    return self
end

-- @param endTime, optional.
function Span:finish(endTime)
    if self.is_noop then
        return self
    end

    if endTime == nil then
        self.end_time = Util.timestamp()
    else
        self.end_time = endTime
    end
    self.owner.internal:finishSpan(self)

    return self
end

function Span:setComponentId(componentId)
    if self.is_noop then
        return self
    end
    self.component_id = componentId

    return self
end

function Span:setLayer(spanLayer)
    if self.is_noop then
        return self
    end
    self.layer = spanLayer

    return self
end

function Span:errorOccurred()
    if self.is_noop then
        return self
    end
    self.error_occurred = true

    return self
end

function Span:tag(tagKey, tagValue)
    if self.is_noop then
        return self
    end

    local tag = {key = tagKey, value = tagValue}
    self.tags[#self.tags + 1] = tag

    return self
end

-- @param keyValuePairs, keyValuePairs is a typical {key=value, key1=value1}
function Span:log(timestamp, keyValuePairs)
    if self.is_noop then
        return self
    end

    local logEntity = {time = timestamp, data = keyValuePairs}
    self.logs[#self.logs + 1] = logEntity

    return self
end

-- Return SpanProtocol
function Span:transform()
    local spanBuilder = SpanProtocol:new()
    spanBuilder.spanId = self.span_id
    spanBuilder.parentSpanId = self.parent_span_id
    spanBuilder.startTime = self.start_time
    spanBuilder.endTime = self.end_time
    -- Array of RefProtocol
    if #self.refs > 0 then
        spanBuilder.refs = {}
        for i, ref in ipairs(self.refs)
        do 
            spanBuilder.refs[#spanBuilder.refs + 1] = ref:transform()
        end
    end

    spanBuilder.operationName = self.operation_name
    spanBuilder.peer = self.peer
    if self.is_entry then
        spanBuilder.spanType = 'Entry'
    elseif self.is_exit then
        spanBuilder.spanType = 'Exit'
    else
        spanBuilder.spanType = 'Local'
    end
    if self.layer ~= spanLayer.NONE then
        spanBuilder.spanLayer = self.layer.name
    end
    spanBuilder.componentId = self.component_id
    spanBuilder.isError = self.error_occurred

    spanBuilder.tags = self.tags
    spanBuilder.logs = self.logs

    return spanBuilder
end

return Span
