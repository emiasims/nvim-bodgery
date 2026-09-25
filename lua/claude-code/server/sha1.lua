-- SHA-1 for the websocket handshake. Adapted from claudecode.nvim's server/utils.lua
-- (https://github.com/coder/claudecode.nvim, commit 2390c6e, MIT License, Copyright (c) 2025
-- Coder Technologies), using the `bit` module Neovim provides in place of arithmetic emulation.
local bit = require('bit')
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

--- @param data string
--- @return string digest 20 raw bytes
return function(data)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

  local bits = #data * 8
  local pad = (55 - #data) % 64
  local len = {}
  for i = 7, 0, -1 do
    -- 2^32 splits the length so it stays exact past 32 bits
    local word = i >= 4 and math.floor(bits / 2 ^ 32) or bits % 2 ^ 32
    len[#len + 1] = string.char(band(rshift(word, (i % 4) * 8), 0xFF))
  end
  local msg = data .. '\128' .. ('\0'):rep(pad) .. table.concat(len)

  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i <= 19 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i <= 39 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i <= 59 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      local temp = bit.tobit(rol(a, 5) + f + e + k + w[i])
      a, b, c, d, e = temp, a, rol(b, 30), c, d
    end

    h0 = bit.tobit(h0 + a)
    h1 = bit.tobit(h1 + b)
    h2 = bit.tobit(h2 + c)
    h3 = bit.tobit(h3 + d)
    h4 = bit.tobit(h4 + e)
  end

  local out = {}
  for _, h in ipairs({ h0, h1, h2, h3, h4 }) do
    out[#out + 1] = string.char(
      band(rshift(h, 24), 0xFF),
      band(rshift(h, 16), 0xFF),
      band(rshift(h, 8), 0xFF),
      band(h, 0xFF)
    )
  end
  return table.concat(out)
end
