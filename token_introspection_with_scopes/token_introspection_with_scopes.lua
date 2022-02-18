local policy = require('apicast.policy')
local _M = policy.new('Token Introspection Policy with Scopes')

local cjson = require('cjson.safe')
local http_authorization = require 'resty.http_authorization'
local http_ng = require 'resty.http_ng'
local user_agent = require 'apicast.user_agent'
local resty_env = require('resty.env')
local resty_url = require('resty.url')

local tokens_cache = require('tokens_cache')

local tonumber = tonumber

local new = _M.new

local noop = function() end
local noop_cache = { get = noop, set = noop }

local function create_credential(client_id, client_secret)
  return 'Basic ' .. ngx.encode_base64(table.concat({ client_id, client_secret }, ':'))
end

function _M.new(config)
  local self = new(config)
  self.config = config or {}
  self.auth_type = config.auth_type or "client_id+client_secret"
  --- authorization for the token introspection endpoint.
  -- https://tools.ietf.org/html/rfc7662#section-2.2
  if self.auth_type == "client_id+client_secret" then
    self.credential = create_credential(self.config.client_id or '', self.config.client_secret or '')
    self.introspection_url = config.introspection_url
  end
  self.http_client = http_ng.new{
    backend = config.client,
    options = {
      headers = {
        ['User-Agent'] = user_agent()
      },
      ssl = { verify = resty_env.enabled('OPENSSL_VERIFY') }
    }
  }

  local max_cached_tokens = tonumber(config.max_cached_tokens) or 0
  self.caching_enabled = max_cached_tokens > 0

  if self.caching_enabled then
    self.tokens_cache = tokens_cache.new(
      config.max_ttl_tokens, config.max_cached_tokens)
  else
    self.tokens_cache = noop_cache
  end

  --Split paths--
  local security = {}
  for k=1, #self.config.scopes do
    for s in string.gmatch(self.config.scopes[k].protected_uris, "[^,]+") do
      if security[s] == nil then
        security[s]=self.config.scopes[k].scope
      else
        security[s]=security[s] .. "," .. self.config.scopes[k].scope
      end
    end
  end
  self.security = security
  --Security has all the protected paths

  return self
end

--- OAuth 2.0 Token Introspection defined in RFC7662.
-- https://tools.ietf.org/html/rfc7662
local function introspect_token(self, token)
  local cached_token_info = self.tokens_cache:get(token)
  if cached_token_info then return cached_token_info end

  --- Parameters for the token introspection endpoint.
  -- https://tools.ietf.org/html/rfc7662#section-2.1
  local res, err = self.http_client.post{self.introspection_url , { token = token, token_type_hint = 'access_token'},
    headers = {['Authorization'] = self.credential}}
  if err then
    ngx.log(ngx.WARN, 'token introspection error: ', err, ' url: ', self.introspection_url)
    return { active = false }
  end

  if res.status == 200 then
    local token_info, decode_err = cjson.decode(res.body)
    if type(token_info) == 'table' then
      self.tokens_cache:set(token, token_info)
      return token_info
    else
      ngx.log(ngx.ERR, 'failed to parse token introspection response:', decode_err)
      return { active = false }
    end
  else
    ngx.log(ngx.WARN, 'failed to execute token introspection. status: ', res.status)
    return { active = false }
  end
end

local function split(str, character)
  result = {}
  for s in string.gmatch(str, "[^"..character.."]+") do
      table.insert(result, s)
  end
  return result
end

local function erasepath(path)
  if path:match('(.*)/$') then 
    return path:match('(.*)/$')
  else 
    return path 
  end
end

function _M:access(context)
  if self.auth_type == "use_3scale_oidc_issuer_endpoint" then
    if not context.proxy.oauth then
      ngx.status = context.service.auth_failed_status
      ngx.say(context.service.error_auth_failed)
      return ngx.exit(ngx.status)
    end
    local components = resty_url.parse(context.service.oidc.issuer_endpoint)
    self.credential = create_credential(components.user, components.password)
    self.introspection_url = context.proxy.oauth.config.token_introspection_endpoint
  end

  local uri_path = erasepath(ngx.var.uri)

  scope_needed={}
  if self.security[uri_path] ~= nil then
    scope_needed=split(self.security[uri_path], ",")
  end
  
  if #scope_needed > 0 then
    if self.introspection_url then
      local authorized = false
      local authorization = http_authorization.new(ngx.var.http_authorization)
      local access_token = authorization.token
      --- Introspection Response must have an "active" boolean value.
      -- https://tools.ietf.org/html/rfc7662#section-2.2
      token_info = introspect_token(self, access_token)
      if not token_info.active == true then
        ngx.log(ngx.INFO, 'token introspection for access token ', access_token, ': token not active')
        ngx.status = context.service.auth_failed_status
        ngx.say(context.service.error_auth_failed)
        return ngx.exit(ngx.status)
      else
        token_scopes=split(token_info.scope, " ")
        if #token_scopes > 0 then  
          for i=1, #token_scopes do
            for h=1, #scope_needed do
              if token_scopes[i] == scope_needed[h] then
                authorized = true
                break
              end
            end
          end
          if not authorized then
            ngx.log(ngx.INFO, 'token introspection for access token ', access_token, ': dont have the scope needed')
            ngx.status = context.service.auth_failed_status
            ngx.say(context.service.error_auth_failed)
            return ngx.exit(ngx.status)
          end
        else  
          ngx.log(ngx.INFO, 'token without scopes')
          ngx.status = context.service.auth_failed_status
          ngx.say(context.service.error_auth_failed)
          return ngx.exit(ngx.status)
        end
      end
    end
  end
end

return _M
