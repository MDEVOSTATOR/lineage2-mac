// Mouse-only bridge inside NNG's private Wine prefix. No sockets, keyboard
// input, game memory access, credentials, installation, or persistence.
package main

import (
 "bufio"
 "encoding/json"
 "fmt"
 "os"
 "runtime"
 "syscall"
 "time"
 "unsafe"
)

type mouseInput struct { Kind uint32; X,Y int32; Data,Flags,Time uint32; Extra uintptr }
type command struct { Seq int `json:"seq"`; Type string `json:"type"`; X,Y int32; Wheel int32 }
type rect struct { Left,Top,Right,Bottom int32 }
var user=syscall.NewLazyDLL("user32.dll")
var kernel=syscall.NewLazyDLL("kernel32.dll")
var output=json.NewEncoder(os.Stdout)
func send(items ...mouseInput)bool {
 if len(items)==0{return true}
 n,_,_:=user.NewProc("SendInput").Call(uintptr(len(items)),uintptr(unsafe.Pointer(&items[0])),unsafe.Sizeof(mouseInput{}))
 return n==uintptr(len(items))
}
func button(down bool)mouseInput {flag:=uint32(0x10);if down{flag=8};return mouseInput{Flags:flag,Extra:0x4e4e47}}
func rightDown()bool {v,_,_:=user.NewProc("GetAsyncKeyState").Call(2);return v&0x8000!=0}
func gameWindow()(uintptr,uint32) {
 var chosen uintptr;var pid uint32;var area int64
 callback:=syscall.NewCallback(func(hwnd,param uintptr)uintptr {
  visible,_,_:=user.NewProc("IsWindowVisible").Call(hwnd);if visible==0{return 1}
  var title [128]uint16;user.NewProc("GetWindowTextW").Call(hwnd,uintptr(unsafe.Pointer(&title[0])),128)
  if syscall.UTF16ToString(title[:])!="Lineage II"{return 1}
  var r rect;user.NewProc("GetClientRect").Call(hwnd,uintptr(unsafe.Pointer(&r)))
  size:=int64(r.Right-r.Left)*int64(r.Bottom-r.Top)
  iconic,_,_:=user.NewProc("IsIconic").Call(hwnd)
  if iconic!=0 {size=1<<32}
  if iconic==0&&(r.Right-r.Left<400||r.Bottom-r.Top<300)||size<=area{return 1}
  var owner uint32;user.NewProc("GetWindowThreadProcessId").Call(hwnd,uintptr(unsafe.Pointer(&owner)))
  if owner!=0 {chosen=hwnd;pid=owner;area=size};return 1
 })
 user.NewProc("EnumWindows").Call(callback,0);return chosen,pid
}
func foregroundPID()uint32 {
 hwnd,_,_:=user.NewProc("GetForegroundWindow").Call();var pid uint32
 user.NewProc("GetWindowThreadProcessId").Call(hwnd,uintptr(unsafe.Pointer(&pid)));return pid
}
// The owner can temporarily disable native frame resizing while the
// renderer's live-resize faults are investigated. No polling or hooks.
func fixedWindowRequested()bool {
 data,err:=os.ReadFile(`C:\NNG\nng-mac-window.json`)
 if err!=nil{return false}
 var settings struct{NativeResize *bool `json:"native_resize"`}
 return json.Unmarshal(data,&settings)==nil&&settings.NativeResize!=nil&&!*settings.NativeResize
}
func fixWindowFrame(hwnd uintptr)bool {
 // Keep WS_MINIMIZEBOX. Removing WS_THICKFRAME/WS_MAXIMIZEBOX changes
 // native resize affordances without moving or resizing the client area.
 const blocked=uint32(0x00050000)
 index:=^uintptr(15) // GWL_STYLE = -16, including on the 32-bit bridge.
 old,_,_:=user.NewProc("GetWindowLongW").Call(hwnd,index)
 if uint32(old)&blocked!=0 {user.NewProc("SetWindowLongW").Call(hwnd,index,uintptr(uint32(old)&^blocked))}
 after,_,_:=user.NewProc("GetWindowLongW").Call(hwnd,index)
 return uint32(after)&blocked==0&&uint32(after)!=0
}
func canary() {
 // Caller also uses a disposable prefix. Never permit this mode with a game.
 hwnd,_:=gameWindow();if os.Getenv("NNG_INPUT_CANARY")!="1"||hwnd!=0{fmt.Fprintln(os.Stderr,"canary denied");os.Exit(2)}
 if rightDown(){fmt.Fprintln(os.Stderr,"button already held");os.Exit(2)}
 downSent:=send(button(true));time.Sleep(40*time.Millisecond);observed:=rightDown()
 upSent:=send(button(false));time.Sleep(40*time.Millisecond);released:=!rightDown()
 output.Encode(map[string]interface{}{"input_struct_bytes":unsafe.Sizeof(mouseInput{}),"down_sent":downSent,"down_observed":observed,"up_sent":upSent,"up_observed":released,"pass":downSent&&observed&&upSent&&released})
 if !(downSent&&observed&&upSent&&released){os.Exit(1)}
}
func main() {
 runtime.LockOSThread();defer runtime.UnlockOSThread()
 if len(os.Args)==2&&os.Args[1]=="--canary"{canary();return}
 if len(os.Args)==2&&os.Args[1]=="--restore" {
  hwnd,pid:=gameWindow();if hwnd==0{output.Encode(map[string]interface{}{"error":"no_game_window"});os.Exit(2)}
  if fixedWindowRequested(){fixWindowFrame(hwnd)}
  user.NewProc("ShowWindowAsync").Call(hwnd,9)
  user.NewProc("SetForegroundWindow").Call(hwnd)
  output.Encode(map[string]interface{}{"restore_requested":true,"windows_pid":pid});return
 }
 commands:=make(chan command,64)
 go func(){
  defer close(commands);scanner:=bufio.NewScanner(os.Stdin);scanner.Buffer(make([]byte,1024),1024)
  for scanner.Scan(){var c command;if json.Unmarshal(scanner.Bytes(),&c)==nil{commands<-c}}
 }()
 hwnd,pid:=gameWindow()
 if hwnd==0 {output.Encode(map[string]interface{}{"waiting_for_game_window":true})}
 // Startup may precede the real window (splash/AGP). Wait only at startup;
 // EOF from the native parent also stops this wait when the game exits.
 waiting:=time.NewTicker(500*time.Millisecond)
 for hwnd==0 {
  select {
  case _,ok:=<-commands:if !ok{waiting.Stop();return}
  case <-waiting.C:hwnd,pid=gameWindow()
  }
 }
 waiting.Stop()
 fixedWindow:=fixedWindowRequested()
 if fixedWindow&&!fixWindowFrame(hwnd){output.Encode(map[string]interface{}{"error":"window_frame_policy_failed"});return}
 process,_,_:=kernel.NewProc("OpenProcess").Call(0x100000,0,uintptr(pid));if process==0{output.Encode(map[string]interface{}{"error":"game_watch_failed"});return}
 defer kernel.NewProc("CloseHandle").Call(process)
 exited:=make(chan struct{})
 go func(){kernel.NewProc("WaitForSingleObject").Call(process,0xffffffff);close(exited)}()
 holding:=false;injected:=0;activeSeq:=0
 release:=func(){if holding{send(button(false));holding=false}}
 defer release()
 timer:=time.NewTimer(time.Hour);timer.Stop();defer timer.Stop();var timeout <-chan time.Time
 report:=func(extra map[string]interface{}){extra["seq"]=activeSeq;extra["injected_inputs"]=injected;extra["holding"]=holding;extra["windows_pid"]=pid;output.Encode(extra)}
 report(map[string]interface{}{"ready":true,"input_struct_bytes":unsafe.Sizeof(mouseInput{}),"foreground_windows_pid":foregroundPID(),"native_resize_locked":fixedWindow})
 for {
  select {
  case <-exited:return
  case <-timeout:activeSeq=0;release();timeout=nil;report(map[string]interface{}{"released":true})
  case c,ok:=<-commands:
   if !ok{return};activeSeq=c.Seq
   switch c.Type {
   case "release":release();timer.Stop();timeout=nil;report(map[string]interface{}{"released":true})
   case "focus":
    // Native parent sends this ONLY while the validated Mac game is frontmost.
    if fixedWindow {fixWindowFrame(hwnd)}
    user.NewProc("SetForegroundWindow").Call(hwnd)
    report(map[string]interface{}{"focused":foregroundPID()==pid})
   case "camera":
    if foregroundPID()!=pid {release();report(map[string]interface{}{"focused":false});continue}
    if c.X < -60||c.X>60||c.Y < -60||c.Y>60 {continue}
    items:=[]mouseInput{}
    if !holding {
     // Do not take ownership of a right button physically held by the user.
     if rightDown(){report(map[string]interface{}{"error":"physical_right_button_held"});continue}
     items=append(items,button(true))
    }
    items=append(items,mouseInput{X:c.X,Y:c.Y,Flags:0x2001,Extra:0x4e4e47})
    if !send(items...){release();report(map[string]interface{}{"error":"SendInput_failed"});continue}
    holding=true;injected+=len(items);if !timer.Stop(){select{case <-timer.C:default:}};timer.Reset(180*time.Millisecond);timeout=timer.C
    report(map[string]interface{}{"camera":true,"right_button_down":rightDown()})
   case "zoom":
    release();timer.Stop();timeout=nil
    if foregroundPID()!=pid{report(map[string]interface{}{"focused":false});continue}
    if c.Wheel < -2||c.Wheel>2||c.Wheel==0{continue}
    if !send(mouseInput{Data:uint32(c.Wheel*120),Flags:0x800,Extra:0x4e4e47}){report(map[string]interface{}{"error":"SendInput_failed"});continue}
    injected++;report(map[string]interface{}{"zoom":true})
   }
  }
 }
}
