#!/usr/bin/env python3
"""把 LuCI 的 .po 编译成 .lmo（等价于上游 po2lmo），用于真机即时验证中文。

固件构建时由 luci.mk 自动完成同样的转换；这个脚本只用于「不重新编译固件也要看到
中文」的场景（把生成的 .lmo 推到 /usr/lib/lua/luci/i18n/）。

格式（与 modules/luci-base/src/po2lmo.c + lib/lmo.c 一致）：
    [数据块（每条字符串按 4 字节对齐）]
    [索引：key_id, val_id, offset, length —— 均为大端 uint32，按 key_id 升序]
    [uint32 大端：索引起始偏移]
其中 key_id = sfh_hash(msgid, len, len)，val_id = sfh_hash(msgstr, len, len)。

用法:
    python3 scripts/make-lmo.py <input.po> <output.lmo> [--verify]
"""
import struct
import sys


def sfh_hash(data: bytes, init: int) -> int:
    """SuperFastHash（Paul Hsieh），与 lmo.c 的 sfh_hash 一致（init 传长度）。"""
    length = len(data)
    if length <= 0:
        return 0

    def get16(d, i):
        return d[i] | (d[i + 1] << 8)

    h = init & 0xFFFFFFFF
    rem = length & 3
    n = length >> 2
    pos = 0

    for _ in range(n):
        h = (h + get16(data, pos)) & 0xFFFFFFFF
        tmp = ((get16(data, pos + 2) << 11) ^ h) & 0xFFFFFFFF
        h = ((h << 16) ^ tmp) & 0xFFFFFFFF
        pos += 4
        h = (h + (h >> 11)) & 0xFFFFFFFF

    if rem == 3:
        h = (h + get16(data, pos)) & 0xFFFFFFFF
        h ^= (h << 16) & 0xFFFFFFFF
        signed = data[pos + 2] - 256 if data[pos + 2] > 127 else data[pos + 2]
        h = (h ^ ((signed << 18) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
    elif rem == 2:
        h = (h + get16(data, pos)) & 0xFFFFFFFF
        h = (h ^ ((h << 11) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 17)) & 0xFFFFFFFF
    elif rem == 1:
        signed = data[pos] - 256 if data[pos] > 127 else data[pos]
        h = (h + signed) & 0xFFFFFFFF
        h = (h ^ ((h << 10) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 1)) & 0xFFFFFFFF

    h ^= (h << 3) & 0xFFFFFFFF
    h = (h + (h >> 5)) & 0xFFFFFFFF
    h ^= (h << 4) & 0xFFFFFFFF
    h = (h + (h >> 17)) & 0xFFFFFFFF
    h ^= (h << 25) & 0xFFFFFFFF
    h = (h + (h >> 6)) & 0xFFFFFFFF
    return h & 0xFFFFFFFF


def unquote(line: str) -> str:
    """取出 PO 行里第一个引号内的内容并还原转义。"""
    start = line.find('"')
    end = line.rfind('"')
    if start < 0 or end <= start:
        return ''
    raw = line[start + 1:end]
    out = []
    i = 0
    while i < len(raw):
        c = raw[i]
        if c == '\\' and i + 1 < len(raw):
            nxt = raw[i + 1]
            out.append({'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\'}.get(nxt, nxt))
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def parse_po(path):
    entries = []
    msgid = None
    msgstr = None
    target = None

    with open(path, encoding='utf-8') as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            if s.startswith('msgid '):
                # 提交上一条
                if msgid is not None and msgstr:
                    entries.append((msgid, msgstr))
                msgid = unquote(s)
                msgstr = None
                target = 'id'
            elif s.startswith('msgstr '):
                msgstr = unquote(s)
                target = 'str'
            elif s.startswith('"'):
                if target == 'id':
                    msgid += unquote(s)
                elif target == 'str':
                    msgstr = (msgstr or '') + unquote(s)

    if msgid is not None and msgstr:
        entries.append((msgid, msgstr))

    # msgid 为空的是 PO 头（Plural-Forms 等），本转换不需要
    return [(k, v) for k, v in entries if k]


def build_lmo(entries, out_path):
    data = bytearray()
    index = []

    for key, val in entries:
        kb, vb = key.encode('utf-8'), val.encode('utf-8')
        key_id = sfh_hash(kb, len(kb))
        val_id = sfh_hash(vb, len(vb))
        if key_id == val_id:
            continue

        offset = len(data)
        data += vb
        pad = (4 - (len(vb) % 4)) % 4
        data += b'\x00' * pad
        index.append((key_id, val_id, offset, len(vb)))

    index.sort(key=lambda e: e[0])

    idx_offset = len(data)
    blob = bytearray(data)
    for key_id, val_id, offset, length in index:
        blob += struct.pack('>IIII', key_id, val_id, offset, length)
    blob += struct.pack('>I', idx_offset)

    with open(out_path, 'wb') as f:
        f.write(blob)
    return len(index), idx_offset


def verify(path, probes):
    """按 lmo.c 的方式读回来，确认索引与字符串都能命中。"""
    blob = open(path, 'rb').read()
    idx_offset = struct.unpack('>I', blob[-4:])[0]
    count = (len(blob) - idx_offset - 4) // 16
    table = {}
    for i in range(count):
        key_id, val_id, offset, length = struct.unpack('>IIII', blob[idx_offset + i * 16:idx_offset + (i + 1) * 16])
        table[key_id] = blob[offset:offset + length].decode('utf-8')

    ok = True
    for probe in probes:
        kb = probe.encode('utf-8')
        got = table.get(sfh_hash(kb, len(kb)))
        flag = 'OK ' if got is not None else 'MISS'
        if got is None:
            ok = False
        print('  %s %-45s -> %s' % (flag, probe, got))
    return ok


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)

    src, dst = args
    entries = parse_po(src)
    n, idx_offset = build_lmo(entries, dst)
    print('已生成 %s：%d 条词条，数据区 %d 字节' % (dst, n, idx_offset))

    if '--verify' in sys.argv:
        probes = ['Signal strength', 'Network status', 'Data usage',
                  'Carrier aggregation', 'Monthly reset', 'Not assigned']
        sys.exit(0 if verify(dst, probes) else 1)
