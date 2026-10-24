//go:build js

package main

import (
	"net/url"
	"runtime"
	"strings"
	"syscall/js"
)

func benchMode() string {
	q, err := url.ParseQuery(strings.TrimPrefix(js.Global().Get("location").Get("search").String(), "?"))
	if err != nil {
		return ""
	}
	return q.Get("bench")
}

// emit logs a BENCH line to the browser console, where the Playwright harness reads it.
func emit(line string) {
	js.Global().Get("console").Call("log", line)
}

// exitProcess does nothing on the web: the page stays idle after a bench finishes.
func exitProcess() {}

// sinceProcessStartMS is the time since navigation start.
func sinceProcessStartMS() float64 {
	return js.Global().Get("performance").Call("now").Float()
}

// rssMB is the size of the wasm linear memory the Go runtime has obtained from the browser.
func rssMB() float64 {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return float64(ms.Sys) / (1 << 20)
}

// openFile shows the browser file picker; the chosen file arrives on u.files.
func (u *ui) openFile() {
	doc := js.Global().Get("document")
	input := doc.Call("createElement", "input")
	input.Set("type", "file")
	input.Set("accept", ".json,application/json")
	input.Set("onchange", js.FuncOf(func(this js.Value, args []js.Value) any {
		files := input.Get("files")
		if files.Length() == 0 {
			return nil
		}
		files.Index(0).Call("text").Call("then", js.FuncOf(func(_ js.Value, a []js.Value) any {
			select {
			case u.files <- []byte(a[0].String()):
				u.win.Invalidate()
			default:
			}
			return nil
		}))
		return nil
	}))
	input.Call("click")
}

// saveFile offers the model as a download.
func (u *ui) saveFile(data []byte) error {
	g := js.Global()
	blob := g.Get("Blob").New([]any{string(data)}, map[string]any{"type": "application/json"})
	href := g.Get("URL").Call("createObjectURL", blob)
	a := g.Get("document").Call("createElement", "a")
	a.Set("href", href)
	a.Set("download", "model.json")
	a.Call("click")
	g.Get("URL").Call("revokeObjectURL", href)
	return nil
}
