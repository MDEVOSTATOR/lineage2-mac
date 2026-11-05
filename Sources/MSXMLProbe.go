//go:build windows && 386

// Probe the exact 32-bit MSXML failure path used by the High Five client.
// Native COM pointers and vtables are outside the Go heap; build validation
// disables only vet's unsafeptr analyzer for these required syscall casts.
package main

import (
	"encoding/json"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

type guid struct {
	D1     uint32
	D2, D3 uint16
	D4     [8]byte
}

func main() {
	runtime.LockOSThread()
	ole := syscall.NewLazyDLL("ole32.dll")
	init := ole.NewProc("CoInitializeEx")
	create := ole.NewProc("CoCreateInstance")
	uninit := ole.NewProc("CoUninitialize")
	hr, _, _ := init.Call(0, 2)
	defer uninit.Call()
	fmt.Printf("CoInitializeEx HRESULT=%08x\n", uint32(hr))
	iid := guid{0x2933bf95, 0x7b36, 0x11d2, [8]byte{0xb2, 0x0e, 0, 0xc0, 0x4f, 0x98, 0x3e, 0x60}}
	for _, v := range []struct {
		name string
		id   uint32
	}{{"DOMDocument40", 0x88d969c0}, {"DOMDocument60", 0x88d96a05}} {
		cls := guid{v.id, 0xf192, 0x11d4, [8]byte{0xa6, 0x5f, 0, 0x40, 0x96, 0x32, 0x51, 0xe5}}
		var obj uintptr
		h, _, _ := create.Call(uintptr(unsafe.Pointer(&cls)), 0, 1, uintptr(unsafe.Pointer(&iid)), uintptr(unsafe.Pointer(&obj)))
		provider := ""
		if obj != 0 {
			k := syscall.NewLazyDLL("kernel32.dll")
			var module uintptr
			vt := *(*uintptr)(unsafe.Pointer(obj))
			entry := *(*uintptr)(unsafe.Pointer(vt))
			k.NewProc("GetModuleHandleExW").Call(6, entry, uintptr(unsafe.Pointer(&module)))
			if module != 0 {
				path := make([]uint16, 1024)
				n, _, _ := k.NewProc("GetModuleFileNameW").Call(module, uintptr(unsafe.Pointer(&path[0])), uintptr(len(path)))
				provider = syscall.UTF16ToString(path[:n])
			}
		}
		out, _ := json.Marshal(map[string]interface{}{"class": v.name, "hresult": fmt.Sprintf("%08x", uint32(h)), "nonnull": obj != 0, "provider": provider})
		fmt.Println(string(out))
		if obj != 0 && v.name == "DOMDocument40" {
			vt := *(*uintptr)(unsafe.Pointer(obj))
			method := func(i uintptr) uintptr { return *(*uintptr)(unsafe.Pointer(vt + i*4)) }
			syscall.SyscallN(method(63), obj, 0)
			syscall.SyscallN(method(68), obj, uintptr(0xffff))
			oa := syscall.NewLazyDLL("oleaut32.dll")
			alloc := oa.NewProc("SysAllocString")
			free := oa.NewProc("SysFreeString")
			text, _ := syscall.UTF16PtrFromString(`C:\nng-msxml4\does-not-exist-Schema.xsd`)
			bstr, _, _ := alloc.Call(uintptr(unsafe.Pointer(text)))
			var loaded int16
			loadhr, _, _ := syscall.SyscallN(method(58), obj, 8, 0, bstr, 0, uintptr(unsafe.Pointer(&loaded)))
			free.Call(bstr)
			var pe uintptr
			phr, _, _ := syscall.SyscallN(method(60), obj, uintptr(unsafe.Pointer(&pe)))
			result := map[string]interface{}{"missing_file_load_hr": fmt.Sprintf("%08x", uint32(loadhr)), "loaded": loaded, "parse_error_hr": fmt.Sprintf("%08x", uint32(phr)), "parse_error_nonnull": pe != 0}
			if pe != 0 {
				pv := *(*uintptr)(unsafe.Pointer(pe))
				var code int32
				var url uintptr
				syscall.SyscallN(*(*uintptr)(unsafe.Pointer(pv + 7*4)), pe, uintptr(unsafe.Pointer(&code)))
				uhr, _, _ := syscall.SyscallN(*(*uintptr)(unsafe.Pointer(pv + 8*4)), pe, uintptr(unsafe.Pointer(&url)))
				result["parse_error_code"] = fmt.Sprintf("%08x", uint32(code))
				result["get_url_hr"] = fmt.Sprintf("%08x", uint32(uhr))
				result["url_nonnull"] = url != 0
				if url != 0 {
					free.Call(url)
				}
				syscall.SyscallN(*(*uintptr)(unsafe.Pointer(pv + 2*4)), pe)
			}
			out, _ := json.Marshal(result)
			fmt.Println(string(out))
		}
		if obj != 0 {
			vt := *(*uintptr)(unsafe.Pointer(obj))
			release := *(*uintptr)(unsafe.Pointer(vt + 2*unsafe.Sizeof(obj)))
			syscall.SyscallN(release, obj)
		}
	}
}
