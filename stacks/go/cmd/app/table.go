package main

import (
	"image"
	"sort"
	"strconv"

	"gioui.org/layout"
	"gioui.org/op"
	"gioui.org/op/clip"
	"gioui.org/op/paint"
	"gioui.org/unit"
	"gioui.org/widget"
	"gioui.org/widget/material"
)

var tableColumns = [...]struct {
	title string
	width unit.Dp
}{{"ID", 60}, {"i", 60}, {"j", 60}, {"L (m)", 70}, {"max|M|", 90}, {"N_i", 90}}

const rowHeight = unit.Dp(22)

// table is the virtualized, sortable member table.
type table struct {
	list     widget.List
	heads    [len(tableColumns)]widget.Clickable
	sortCol  int
	desc     bool
	rows     []int32
	needSort bool
}

func newTable() *table {
	t := &table{needSort: true}
	t.list.Axis = layout.Vertical
	return t
}

func (t *table) value(s *state, col int, k int32) float64 {
	sol := s.sol
	switch col {
	case 0:
		return float64(sol.Members[k].ID)
	case 1:
		return float64(sol.Members[k].I)
	case 2:
		return float64(sol.Members[k].J)
	case 3:
		return sol.MemL[k]
	case 4:
		if int(k) < len(s.memMaxM) {
			return s.memMaxM[k]
		}
	case 5:
		if _, cs := s.current(); cs != nil {
			return cs.EndForces[6*k]
		}
	}
	return 0
}

// resort rebuilds the row order. It is deliberately not run during drags.
func (t *table) resort(s *state) {
	n := len(s.sol.Members)
	if len(t.rows) != n {
		t.rows = make([]int32, n)
		for i := range t.rows {
			t.rows[i] = int32(i)
		}
	}
	col, desc := t.sortCol, t.desc
	sort.SliceStable(t.rows, func(a, b int) bool {
		va, vb := t.value(s, col, t.rows[a]), t.value(s, col, t.rows[b])
		if desc {
			return va > vb
		}
		return va < vb
	})
	t.needSort = false
}

func (t *table) layout(gtx layout.Context, th *material.Theme, s *state, dragging bool) layout.Dimensions {
	if s.sol == nil {
		return layout.Dimensions{Size: gtx.Constraints.Max}
	}
	for i := range t.heads {
		for t.heads[i].Clicked(gtx) {
			if t.sortCol == i {
				t.desc = !t.desc
			} else {
				t.sortCol, t.desc = i, false
			}
			t.needSort = true
		}
	}
	if len(t.rows) != len(s.sol.Members) || (t.needSort && !dragging) {
		t.resort(s)
	}
	return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
		layout.Rigid(func(gtx layout.Context) layout.Dimensions { return t.header(gtx, th) }),
		layout.Flexed(1, func(gtx layout.Context) layout.Dimensions {
			return material.List(th, &t.list).Layout(gtx, len(t.rows), func(gtx layout.Context, i int) layout.Dimensions {
				return t.row(gtx, th, s, t.rows[i])
			})
		}),
	)
}

func (t *table) header(gtx layout.Context, th *material.Theme) layout.Dimensions {
	h := gtx.Dp(rowHeight)
	x := 0
	for i, c := range tableColumns {
		w := gtx.Dp(c.width)
		title := c.title
		if i == t.sortCol {
			if t.desc {
				title += " v"
			} else {
				title += " ^"
			}
		}
		st := op.Offset(image.Pt(x, 0)).Push(gtx.Ops)
		cg := gtx
		cg.Constraints = layout.Exact(image.Pt(w, h))
		t.heads[i].Layout(cg, func(g layout.Context) layout.Dimensions {
			l := material.Caption(th, title)
			return layout.Inset{Left: 4}.Layout(g, l.Layout)
		})
		st.Pop()
		x += w
	}
	return layout.Dimensions{Size: image.Pt(x, h)}
}

func (t *table) row(gtx layout.Context, th *material.Theme, s *state, k int32) layout.Dimensions {
	h := gtx.Dp(rowHeight)
	var cells [len(tableColumns)]string
	m := s.sol.Members[k]
	cells[0] = strconv.Itoa(m.ID)
	cells[1] = strconv.Itoa(m.I)
	cells[2] = strconv.Itoa(m.J)
	cells[3] = strconv.FormatFloat(s.sol.MemL[k], 'f', 3, 64)
	cells[4] = strconv.FormatFloat(t.value(s, 4, k), 'g', 5, 64)
	cells[5] = strconv.FormatFloat(t.value(s, 5, k), 'g', 5, 64)
	x := 0
	if k%2 == 1 {
		paint.FillShape(gtx.Ops, colBackground, clip.Rect{Max: image.Pt(gtx.Constraints.Max.X, h)}.Op())
	}
	for i, c := range tableColumns {
		w := gtx.Dp(c.width)
		st := op.Offset(image.Pt(x, 0)).Push(gtx.Ops)
		cg := gtx
		cg.Constraints = layout.Exact(image.Pt(w, h))
		layout.Inset{Left: 4}.Layout(cg, material.Caption(th, cells[i]).Layout)
		st.Pop()
		x += w
	}
	return layout.Dimensions{Size: image.Pt(gtx.Constraints.Max.X, h)}
}
