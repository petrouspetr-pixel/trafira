// SPDX-License-Identifier: MIT
package main

import (
    "net"
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
