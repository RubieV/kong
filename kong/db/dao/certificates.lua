local singletons = require "kong.singletons"
local cjson      = require "cjson"
local utils      = require "kong.tools.utils"

-- Get an array of SNI names from either
-- an array(sort) or ngx.null(return {})
-- Returns an error if the list has duplicates
-- Returns nil if input is falsy.
local function parse_name_list(input, errors)
  local name_list
  if type(input) == "table" then
    name_list = utils.shallow_copy(input)

  elseif input == ngx.null then
    name_list = {}

  else
    return nil
  end

  local found = {}
  for _, name in ipairs(name_list) do
    if found[name] then
      local msg   = "duplicate sni in request: " .. name
      local err_t = errors:invalid_input(msg)
      return nil, tostring(err_t), err_t
    end
    found[name] = true
  end

  table.sort(name_list)
  return setmetatable(name_list, cjson.empty_array_mt)
end


local _Certificates = {}

-- Creates a certificate
-- If the provided cert has a field called "snis" it will be used to generate server
-- names associated to the cert, after being parsed by parse_name_list.
-- Returns a certificate with the snis sorted alphabetically.
function _Certificates:insert_with_name_list(cert)
  local db = singletons.db
  local name_list, err, err_t = parse_name_list(cert.snis, self.errors)
  if err then
    return nil, err, err_t
  end

  if name_list then
    local ok, err, err_t = db.snis:check_list_is_new(name_list)
    if not ok then
      return nil, err, err_t
    end
  end

  cert.snis = nil
  cert, err, err_t = self:insert(cert)
  if not cert then
    return nil, err, err_t
  end
  cert.snis = name_list or cjson.empty_array

  if name_list then
    local ok, err, err_t = db.snis:insert_list({id = cert.id}, name_list)
    if not ok then
      return nil, err, err_t
    end
  end

  return cert
end

-- Updates a certificate
-- If the cert has a "snis" attribute it will be used to update the SNIs
-- associated to the cert.
--   * If the cert had any names associated which are not on `snis`, they will be
--     removed.
--   * Any new certificates will be added to the db.
-- Returns an error if any of the new certificates where already assigned to a cert different
-- from the one identified by cert_pk
function _Certificates:update_with_name_list(cert_pk, cert)
  local db = singletons.db
  local name_list, err, err_t = parse_name_list(cert.snis, self.errors)
  if err then
    return nil, err, err_t
  end

  if name_list then
    local ok, err, err_t =
      db.snis:check_list_is_new_or_in_cert(cert_pk, name_list)
    if not ok then
      return nil, err, err_t
    end
  end

  -- update certificate if necessary
  if cert.key or cert.cert then
    cert.snis = nil
    cert, err, err_t = self:update(cert_pk, cert)
    if err then
      return nil, err, err_t
    end
  end

  if name_list then
    cert.snis = name_list

    local ok, err, err_t = db.snis:update_list(cert_pk, name_list)
    if not ok then
      return nil, err, err_t
    end

  else
    cert.snis, err, err_t = db.snis:list_for_certificate(cert_pk)
    if not cert.snis then
      return nil, err, err_t
    end
  end

  return cert
end


-- Returns the certificate identified by cert_pk but adds the
-- `snis` pseudo attribute to it. It is an array of strings
-- representing the SNIs associated to the certificate.
function _Certificates:select_with_name_list(cert_pk)
  local db = singletons.db

  local cert, err, err_t = db.certificates:select(cert_pk)
  if err_t then
    return nil, err, err_t
  end

  if not cert then
    local err_t = self.errors:not_found(cert_pk)
    return nil, tostring(err_t), err_t
  end

  cert.snis, err, err_t = db.snis:list_for_certificate(cert_pk)
  if err_t then
    return nil, err, err_t
  end

  return cert
end

-- Returns a page of certificates, each with the `snis` pseudo-attribute
-- associated to them. This method does N+1 queries, but for now we are limited
-- by the DAO's select options (we can't query for "all the SNIs for this
-- list of certificate ids" in one go).
function _Certificates:page_with_name_list(size, offset)
  local db = singletons.db
  local certs, err, err_t, offset = self:page(size, offset)
  if not certs then
    return nil, err, err_t
  end

  for i=1, #certs do
    local cert = certs[i]
    local snis, err, err_t =
      db.snis:list_for_certificate({ id = cert.id })
    if not snis then
      return nil, err, err_t
    end
    cert.snis = snis
  end

  return certs, nil, nil, offset
end

-- Overrides the default delete function by cascading-deleting all the SNIs
-- associated to the certificate
function _Certificates:delete(cert_pk)
  local db = singletons.db

  local name_list, err, err_t =
    db.snis:list_for_certificate(cert_pk)
  if not name_list then
    return nil, err, err_t
  end

  local ok, err, err_t = db.snis:delete_list(name_list)
  if not ok then
    return nil, err, err_t
  end

  return self.super.delete(self, cert_pk)
end


return _Certificates
