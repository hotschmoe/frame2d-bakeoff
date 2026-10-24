//go:build js && wasm

// Command wasm is the Go js/wasm build of the engine bridge. It registers a global `f2dEngine` object
// whose methods mirror the C ABI of the desktop library; float buffers are copied into JS Float64Arrays.
package main

import (
	"syscall/js"
	"unsafe"

	"frame2d/bridge/session"
)

func f64array(f []float64) js.Value {
	arr := js.Global().Get("Float64Array").New(len(f))
	if len(f) == 0 {
		return arr
	}
	u8 := js.Global().Get("Uint8Array").New(arr.Get("buffer"))
	js.CopyBytesToJS(u8, unsafe.Slice((*byte)(unsafe.Pointer(&f[0])), len(f)*8))
	return arr
}

func main() {
	api := js.Global().Get("Object").New()
	reg := func(name string, fn func(a []js.Value) any) {
		api.Set(name, js.FuncOf(func(_ js.Value, a []js.Value) any { return fn(a) }))
	}
	sess := func(a []js.Value) *session.Session { return session.Get(int32(a[0].Int())) }

	reg("noop", func(a []js.Value) any { return nil })
	reg("echo", func(a []js.Value) any { return f64array(session.Echo(a[0].Int())) })
	reg("loadJson", func(a []js.Value) any { return session.FromJSON([]byte(a[0].String())) })
	reg("gen", func(a []js.Value) any { return session.Gen(a[0].Int(), a[1].Int()) })
	reg("free", func(a []js.Value) any { session.Free(int32(a[0].Int())); return nil })
	reg("lastError", func(a []js.Value) any { b := session.LastError(); return string(b[:len(b)-1]) })
	reg("counts", func(a []js.Value) any {
		c := sess(a).Counts()
		return f64array([]float64{float64(c[0]), float64(c[1]), float64(c[2])})
	})
	reg("geometry", func(a []js.Value) any { return f64array(sess(a).Geometry()) })
	reg("result", func(a []js.Value) any { return f64array(sess(a).Result()) })
	reg("stats", func(a []js.Value) any { return f64array(sess(a).Stats()) })
	reg("caseIds", func(a []js.Value) any { return string(sess(a).CaseIDs()) })
	reg("setNode", func(a []js.Value) any {
		sess(a).SetNode(a[1].Int(), a[2].Float(), a[3].Float())
		return nil
	})
	reg("solve", func(a []js.Value) any { return sess(a).Solve(a[1].Int()) })
	reg("toJson", func(a []js.Value) any { return string(sess(a).ToJSON()) })
	js.Global().Set("f2dEngine", api)
	select {}
}
