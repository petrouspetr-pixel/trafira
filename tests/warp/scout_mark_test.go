// SPDX-License-Identifier: MIT
package main

import (
    "net"
    "context"
    "errors"
    "syscall"
    "testing"
    "golang.org/x/sys/unix"
)
func socketMark(t *testing.T, conn *net.UDPConn) int {
    t.Helper()
    raw,err:=conn.SyscallConn(); if err!=nil {t.Fatal(err)}
    var mark int; var inner error
    if err=raw.Control(func(fd uintptr){mark,inner=unix.GetsockoptInt(int(fd),unix.SOL_SOCKET,unix.SO_MARK)});err!=nil {t.Fatal(err)}
    if inner!=nil {t.Fatal(inner)}
    return mark
}
func TestTrafiraSocketMark(t *testing.T) {
    const mark=0x08000000
    for _,before:=range []bool{true,false} {
        b:=newDeviceBind("")
        if before {if err:=b.SetMark(mark);err!=nil {t.Fatal(err)}}
        if _,_,err:=b.Open(0);err!=nil {t.Fatal(err)}
        if !before {if err:=b.SetMark(mark);err!=nil {t.Fatal(err)}}
        got:=socketMark(t,b.conn); b.Close()
        if got!=mark {t.Fatalf("SetMark(beforeOpen=%v): got %#x, want %#x",before,got,mark)}
    }
    unrelated,err:=net.ListenUDP("udp4",&net.UDPAddr{IP:net.IPv4(127,0,0,1)});if err!=nil {t.Fatal(err)}
    defer unrelated.Close()
    if got:=socketMark(t,unrelated);got!=0 {t.Fatalf("unrelated socket inherited %#x",got)}
}

type rejectedRaw struct{}
func (rejectedRaw) Control(f func(uintptr)) error {return errors.New("denied")}
func (rejectedRaw) Read(f func(uintptr)bool) error {return errors.New("denied")}
func (rejectedRaw) Write(f func(uintptr)bool) error {return errors.New("denied")}
var _ syscall.RawConn = rejectedRaw{}
func TestMarkedRegistrationAndDNS(t *testing.T) {
 old:=trafiraMark;trafiraMark=0x08000000;defer func(){trafiraMark=old}()
 conn,err:=markedResolver().Dial(context.Background(),"udp4","ignored.invalid:53")
 if err!=nil {t.Fatal(err)};defer conn.Close()
 // UDP connect creates a socket but sends no DNS packet to Cloudflare.
 if got:=socketMark(t,conn.(*net.UDPConn));got!=int(trafiraMark){t.Fatalf("DNS mark %#x",got)}
 listener,err:=net.ListenTCP("tcp4",&net.TCPAddr{IP:net.IPv4(127,0,0,1)})
 if err!=nil {t.Fatal(err)};defer listener.Close()
 raw,err:=listener.SyscallConn();if err!=nil {t.Fatal(err)}
 if err=markedControl("",0,uint32(trafiraMark))("tcp4","162.159.192.1:443",raw);err!=nil{t.Fatal(err)}
 var got int;raw.Control(func(fd uintptr){got,_=unix.GetsockoptInt(int(fd),unix.SOL_SOCKET,unix.SO_MARK)})
 if got!=int(trafiraMark){t.Fatalf("HTTP mark %#x",got)}
 if err=markedControl("",0,uint32(trafiraMark))("tcp4","198.18.0.1:443",raw);err==nil{t.Fatal("FakeIP API accepted")}
 if err=socketMarkControl(rejectedRaw{},uint32(trafiraMark));err==nil{t.Fatal("mark failure ignored")}
 client:=regTransport(nil);defer client.CloseIdleConnections()
 if c,e:=client.DialContext(context.Background(),"tcp4","127.0.0.1:443");e==nil{c.Close();t.Fatal("private registration destination accepted")}
}
