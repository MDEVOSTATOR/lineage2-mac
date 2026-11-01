#!/usr/bin/env python3
"""NNG-only compatibility candidate: let the game own D3D9 backbuffer resize.

Equivalent source edit in upstream v0.15.1 windows/d3d9/src/cursor.rs:1743:
skip the renderer's WM_SIZE branch, then call the original game's wndproc.
The game still receives WM_SIZE and its explicit Reset/CreateDevice works.
This avoids both implicit buffer replacement and cursor reentry from that
branch. The window hook's enter/leave bookkeeping and forwarding stay intact.
The original release hash, instruction, destination, and section are checked.
"""
from pathlib import Path
import argparse, hashlib, json, struct

EXPECTED = '87f6c8d92319ba47313326c58c0ad7313920d86fd6dad7f46385ff0c49b0f706'
RVA = 0x51c29
BEFORE = bytes.fromhex('89f889f9c1e810')
AFTER = bytes.fromhex('e9630000009090')

def patch(data, *, safe_present=True):
    assert hashlib.sha256(data).hexdigest() == EXPECTED, 'Unrecognised renderer build'
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe+4] == b'PE\0\0'
    assert struct.unpack_from('<H', data, pe+4)[0] == 0x14c
    sections = pe+24+struct.unpack_from('<H', data, pe+20)[0]
    offsets = []
    for i in range(struct.unpack_from('<H', data, pe+6)[0]):
        section = sections+40*i
        _, address, size, offset = struct.unpack_from('<IIII', data, section+8)
        if address <= RVA < address+size:
            assert data[section:section+8].rstrip(b'\0') == b'.text'
            offsets.append(offset+RVA-address)
    assert len(offsets) == 1
    offset = offsets[0]
    assert data[offset:offset+len(BEFORE)] == BEFORE
    assert RVA+5+struct.unpack_from('<i', AFTER, 1)[0] == 0x51c91
    result = data[:offset]+AFTER+data[offset+len(BEFORE):]
    assert len(result) == len(data)
    assert [i for i, (x,y) in enumerate(zip(data,result)) if x != y] == list(range(offset,offset+len(BEFORE)))
    if safe_present:
        # Source equivalent: omit capture::poll() from DeviceInner::present.
        # GetAsyncKeyState pumps Wine window events, allowing a nested final
        # Release while this frame still owns references into DeviceInner.
        # The renderer capture hotkey is diagnostic-only; game input is intact.
        # Keep the unreachable import operand intact: its base relocation
        # must not overlap a replacement jump or its displacement.
        poll_rva=0x22f5f
        poll_before=bytes.fromhex('6a50')
        poll_after=bytes.fromhex('eb4b')
        poll_offset=None
        for i in range(struct.unpack_from('<H',data,pe+6)[0]):
            section=sections+40*i
            _,address,size,raw=struct.unpack_from('<IIII',data,section+8)
            if address<=poll_rva<address+size:
                poll_offset=raw+poll_rva-address
        assert poll_offset is not None
        assert result[poll_offset:poll_offset+2]==poll_before
        assert poll_rva+2+struct.unpack_from('<b',poll_after,1)[0]==0x22fac
        result=result[:poll_offset]+poll_after+result[poll_offset+2:]
    # A base relocation is applied by Wine before the code executes. Never
    # replace any of its four target bytes, even with an apparently safe NOP.
    def file_offset(rva):
        for i in range(struct.unpack_from('<H',data,pe+6)[0]):
            section=sections+40*i
            _,address,size,raw=struct.unpack_from('<IIII',data,section+8)
            if address<=rva<address+size:return raw+rva-address
        raise AssertionError('RVA outside file sections')
    reloc_rva,reloc_size=struct.unpack_from('<II',data,pe+24+96+5*8)
    position=file_offset(reloc_rva);end=position+reloc_size
    changed={i for i,(old,new) in enumerate(zip(data,result)) if old!=new}
    while position<end:
        page,block_size=struct.unpack_from('<II',data,position)
        assert block_size>=8 and position+block_size<=end
        for entry_offset in range(position+8,position+block_size,2):
            entry=struct.unpack_from('<H',data,entry_offset)[0]
            if entry>>12==3:
                target=file_offset(page+(entry&0xfff))
                assert not changed.intersection(range(target,target+4)), 'Patch overlaps base relocation'
        position+=block_size
    return result

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('input',type=Path);p.add_argument('output',type=Path);p.add_argument('--safe-present',action='store_true',default=True)
    a=p.parse_args();result=patch(a.input.read_bytes(),safe_present=True);a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_bytes(result)
    print(json.dumps({'source_sha256':EXPECTED,'result_sha256':hashlib.sha256(result).hexdigest(),'rva':hex(RVA),'old':BEFORE.hex(),'new':AFTER.hex(),'changed_bytes':len(BEFORE)+(2 if a.safe_present else 0),'safe_present':a.safe_present}))
