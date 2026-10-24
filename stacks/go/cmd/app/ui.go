package main

import (
	"encoding/json"
	"image"
	"image/color"
	"strconv"
	"strings"
	"time"

	"gioui.org/app"
	"gioui.org/font/gofont"
	"gioui.org/layout"
	"gioui.org/op"
	"gioui.org/text"
	"gioui.org/unit"
	"gioui.org/widget"
	"gioui.org/widget/material"

	"frame2d/engine"
)

const solveLabel = "Solve" // BENCH-EDIT:ui

// ui owns the widgets and the frame loop.
type ui struct {
	win *app.Window
	ops op.Ops
	th  *material.Theme

	st *state
	cv *canvas
	tb *table

	bench *benchRun

	solveBtn, openBtn, saveBtn, genBtn, fitBtn widget.Clickable
	caseBtns                                   []widget.Clickable
	deflBox, momBox                            widget.Bool
	scale                                      widget.Float
	pathEd, bEd, sEd                           widget.Editor

	note    string
	needFit bool
	files   chan []byte // file contents picked by the user (web)
}

func newUI() *ui {
	u := &ui{st: newState(), cv: newCanvas(), tb: newTable(), files: make(chan []byte, 1), needFit: true}
	u.th = material.NewTheme()
	u.th.Shaper = text.NewShaper(text.NoSystemFonts(), text.WithCollection(gofont.Regular()))
	u.th.TextSize = 14
	u.deflBox.Value = true
	u.scale.Value = 0.25
	u.pathEd.SingleLine, u.bEd.SingleLine, u.sEd.SingleLine = true, true, true
	u.pathEd.SetText("model.json")
	u.bEd.SetText("10")
	u.sEd.SetText("10")
	return u
}

func (u *ui) generate(b, s int) {
	u.st.setModel(engine.Generate(b, s), u.cv.size.X, u.cv.size.Y)
	u.needFit = true
	u.tb.needSort = true
	u.cv.selNode = -1
}

func (u *ui) loadModel(data []byte) {
	m, err := engine.ParseModel(data)
	if err != nil {
		u.note = err.Error()
		return
	}
	u.st.setModel(m, u.cv.size.X, u.cv.size.Y)
	u.needFit = true
	u.tb.needSort = true
	u.cv.selNode = -1
	u.note = ""
}

// run is the window event loop.
func (u *ui) run(w *app.Window) error {
	u.win = w
	for {
		switch e := w.Event().(type) {
		case app.DestroyEvent:
			return e.Err
		case app.FrameEvent:
			u.frame(e)
		}
	}
}

func (u *ui) frame(e app.FrameEvent) {
	start := time.Now()
	gtx := app.NewContext(&u.ops, e)
	if u.bench != nil {
		u.bench.before(u, start)
	}
	select {
	case data := <-u.files:
		u.loadModel(data)
	default:
	}
	u.layout(gtx)
	if u.bench != nil && u.bench.wantsFrames() {
		gtx.Execute(op.InvalidateCmd{})
	} else if u.cv.dragNode >= 0 {
		gtx.Execute(op.InvalidateCmd{})
	}
	e.Frame(gtx.Ops)
	if u.bench != nil {
		u.bench.after(u)
	}
}

func (u *ui) buttons(gtx layout.Context) {
	if u.solveBtn.Clicked(gtx) {
		u.st.solve(false)
		u.tb.needSort = true
	}
	if u.fitBtn.Clicked(gtx) {
		u.st.fit(u.cv.size.X, u.cv.size.Y)
	}
	if u.genBtn.Clicked(gtx) {
		b, e1 := strconv.Atoi(strings.TrimSpace(u.bEd.Text()))
		s, e2 := strconv.Atoi(strings.TrimSpace(u.sEd.Text()))
		if e1 != nil || e2 != nil || b < 1 || s < 1 || b > 400 || s > 400 {
			u.note = "Generate: B and S must be integers in 1..400"
		} else {
			u.note = ""
			u.generate(b, s)
		}
	}
	if u.openBtn.Clicked(gtx) {
		u.openFile()
	}
	if u.saveBtn.Clicked(gtx) && u.st.model != nil {
		data, err := json.MarshalIndent(u.st.model, "", " ")
		if err == nil {
			err = u.saveFile(data)
		}
		if err != nil {
			u.note = "Save: " + err.Error()
		} else {
			u.note = "saved"
		}
	}
	if u.st.model != nil {
		for len(u.caseBtns) < len(u.st.model.LoadCases) {
			u.caseBtns = append(u.caseBtns, widget.Clickable{})
		}
		for i, lc := range u.st.model.LoadCases {
			if u.caseBtns[i].Clicked(gtx) {
				u.st.selectCase(lc.ID)
				u.tb.needSort = true
			}
		}
	}
	u.st.showDeflect, u.st.showMoment = u.deflBox.Value, u.momBox.Value
	u.st.defMult = float64(u.scale.Value) * 4
}

func (u *ui) layout(gtx layout.Context) layout.Dimensions {
	u.buttons(gtx)
	return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
		layout.Rigid(u.toolbar),
		layout.Flexed(1, func(gtx layout.Context) layout.Dimensions {
			return layout.Flex{Axis: layout.Horizontal}.Layout(gtx,
				layout.Flexed(1, func(gtx layout.Context) layout.Dimensions {
					if u.needFit && gtx.Constraints.Max.X > 0 {
						u.cv.size = gtx.Constraints.Max
						u.st.fit(u.cv.size.X, u.cv.size.Y)
						u.needFit = false
					}
					return u.cv.layout(gtx, u.st, u.afterPointerSolve)
				}),
				layout.Rigid(func(gtx layout.Context) layout.Dimensions {
					w := gtx.Dp(400)
					if w > gtx.Constraints.Max.X/2 {
						w = gtx.Constraints.Max.X / 2
					}
					gtx.Constraints = layout.Exact(image.Pt(w, gtx.Constraints.Max.Y))
					return u.tb.layout(gtx, u.th, u.st, u.cv.dragNode >= 0)
				}),
			)
		}),
	)
}

// afterPointerSolve re-solves after the canvas moved a node (continuous while dragging, full on release).
func (u *ui) afterPointerSolve() {
	if u.cv.moved {
		u.st.solve(true)
		u.cv.moved = false
	}
	if u.cv.released {
		u.st.solve(false)
		u.cv.released = false
		u.tb.needSort = true
	}
}

func (u *ui) field(ed *widget.Editor, hint string, width unit.Dp) layout.Widget {
	return func(gtx layout.Context) layout.Dimensions {
		gtx.Constraints.Max.X = gtx.Dp(width)
		gtx.Constraints.Min.X = gtx.Constraints.Max.X
		return widget.Border{Color: color.NRGBA{A: 0x60}, Width: 1, CornerRadius: 3}.Layout(gtx, func(gtx layout.Context) layout.Dimensions {
			return layout.UniformInset(4).Layout(gtx, material.Editor(u.th, ed, hint).Layout)
		})
	}
}

func (u *ui) button(c *widget.Clickable, label string) layout.FlexChild {
	return layout.Rigid(func(gtx layout.Context) layout.Dimensions {
		return layout.Inset{Right: 6}.Layout(gtx, material.Button(u.th, c, label).Layout)
	})
}

func (u *ui) toolbar(gtx layout.Context) layout.Dimensions {
	row1 := func(gtx layout.Context) layout.Dimensions {
		return layout.Flex{Axis: layout.Horizontal, Alignment: layout.Middle}.Layout(gtx,
			u.button(&u.solveBtn, solveLabel),
			u.button(&u.openBtn, "Open"),
			u.button(&u.saveBtn, "Save"),
			layout.Rigid(pad(layout.Inset{Right: 6}, u.field(&u.pathEd, "path", 200))),
			layout.Rigid(pad(layout.Inset{Left: 12, Right: 4}, material.Body2(u.th, "B").Layout)),
			layout.Rigid(pad(layout.Inset{Right: 6}, u.field(&u.bEd, "B", 48))),
			layout.Rigid(pad(layout.Inset{Right: 4}, material.Body2(u.th, "S").Layout)),
			layout.Rigid(pad(layout.Inset{Right: 6}, u.field(&u.sEd, "S", 48))),
			u.button(&u.genBtn, "Generate"),
			u.button(&u.fitBtn, "Fit"),
		)
	}
	row2 := func(gtx layout.Context) layout.Dimensions {
		children := []layout.FlexChild{}
		if u.st.model != nil {
			for i, lc := range u.st.model.LoadCases {
				if i >= len(u.caseBtns) {
					break
				}
				b := material.Button(u.th, &u.caseBtns[i], lc.ID)
				if lc.ID != u.st.caseID {
					b.Background = color.NRGBA{R: 0x80, G: 0x80, B: 0x88, A: 0xff}
				}
				children = append(children, layout.Rigid(pad(layout.Inset{Right: 6}, b.Layout)))
			}
		}
		children = append(children,
			layout.Rigid(material.CheckBox(u.th, &u.deflBox, "Deflected").Layout),
			layout.Rigid(material.CheckBox(u.th, &u.momBox, "Moment").Layout),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				gtx.Constraints.Min.X = gtx.Dp(140)
				gtx.Constraints.Max.X = gtx.Dp(140)
				return material.Slider(u.th, &u.scale).Layout(gtx)
			}),
			layout.Rigid(pad(layout.Inset{Left: 12}, func(gtx layout.Context) layout.Dimensions {
				msg := u.st.status()
				if u.note != "" {
					msg = u.note + " | " + msg
				}
				return material.Caption(u.th, msg).Layout(gtx)
			})),
		)
		return layout.Flex{Axis: layout.Horizontal, Alignment: layout.Middle}.Layout(gtx, children...)
	}
	return layout.UniformInset(6).Layout(gtx, func(gtx layout.Context) layout.Dimensions {
		return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
			layout.Rigid(row1),
			layout.Rigid(pad(layout.Inset{Top: 4}, row2)),
		)
	})
}

func pad(i layout.Inset, w layout.Widget) layout.Widget {
	return func(gtx layout.Context) layout.Dimensions { return i.Layout(gtx, w) }
}
