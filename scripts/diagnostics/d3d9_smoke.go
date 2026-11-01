// A bounded D3D9 device/clear/present smoke test, not a game FPS benchmark.
package main

import (
 "encoding/json"
 "fmt"
 "os"
 "runtime"
 "syscall"
 "unsafe"
)

type present struct {
 Width, Height, Format, Count, Multisample, Quality, Swap uint32
 Window uintptr
 Windowed, AutoDepth, DepthFormat, Flags, Refresh, Interval uint32
}
func slot(obj uintptr, n uintptr) uintptr {
 vt:=*(*uintptr)(unsafe.Pointer(obj))
 return *(*uintptr)(unsafe.Pointer(vt+n*unsafe.Sizeof(uintptr(0))))
}
func main() {
 runtime.LockOSThread(); defer runtime.UnlockOSThread()
 out:=map[string]interface{}{"purpose":"device and presentation smoke test; no FPS inference"}
 defer func(){json.NewEncoder(os.Stdout).Encode(out)}()
 user:=syscall.NewLazyDLL("user32.dll")
 class,_:=syscall.UTF16PtrFromString("STATIC")
 title,_:=syscall.UTF16PtrFromString("NNG isolated graphics diagnostic")
 // No WS_VISIBLE: the diagnostic must not steal focus from the live game.
 hwnd,_,err:=user.NewProc("CreateWindowExW").Call(0,uintptr(unsafe.Pointer(class)),uintptr(unsafe.Pointer(title)),0x00cf0000,0,0,640,480,0,0,0,0)
 if hwnd==0 {out["error"]=err.Error();return}
 defer user.NewProc("DestroyWindow").Call(hwnd)
 d3d,_,_:=syscall.NewLazyDLL("d3d9.dll").NewProc("Direct3DCreate9").Call(32)
 if d3d==0 {out["error"]="Direct3DCreate9 returned NULL";return}
 defer syscall.Syscall(slot(d3d,2),1,d3d,0,0)
 pp:=present{Width:640,Height:480,Format:22,Count:1,Swap:1,Window:hwnd,Windowed:1,Interval:0x80000000}
 var device uintptr
 hr,_,_:=syscall.Syscall9(slot(d3d,16),7,d3d,0,1,hwnd,0x40,uintptr(unsafe.Pointer(&pp)),uintptr(unsafe.Pointer(&device)),0,0)
 out["create_device_hresult"]=fmt.Sprintf("%08x",uint32(hr))
 if hr!=0 || device==0 {return}
 defer syscall.Syscall(slot(device,2),1,device,0,0)
 count:=0
 for i:=0;i<12;i++ {
  hr,_,_=syscall.Syscall9(slot(device,43),7,device,0,0,1,0xff205080,0x3f800000,0,0,0)
  if hr!=0 {out["clear_hresult"]=fmt.Sprintf("%08x",uint32(hr));break}
  hr,_,_=syscall.Syscall6(slot(device,17),5,device,0,0,0,0,0)
  if hr!=0 {out["present_hresult"]=fmt.Sprintf("%08x",uint32(hr));break}
  count++
 }
 out["presented_frames"]=count
 out["pass"]=count==12
}
