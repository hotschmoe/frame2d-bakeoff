// Command app is the Frame2D client (Gio): desktop and, built with GOOS=js GOARCH=wasm, web.
package main

import (
	"log"

	"gioui.org/app"
	"gioui.org/unit"
)

func main() {
	mode := benchMode()
	go func() {
		if mode == "boundary" {
			runBoundary()
			exitProcess()
			return
		}
		u := newUI()
		if mode != "" {
			u.bench = newBench(u, mode)
		} else {
			u.generate(10, 10)
		}
		w := new(app.Window)
		w.Option(app.Title("Frame2D"), app.Size(unit.Dp(1000), unit.Dp(640)))
		if err := u.run(w); err != nil {
			log.Println(err)
		}
		exitProcess()
	}()
	app.Main()
}
