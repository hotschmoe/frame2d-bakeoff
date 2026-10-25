package main

import (
	"image"
	"image/color"
	"math"

	"gioui.org/f32"
	"gioui.org/io/event"
	"gioui.org/io/pointer"
	"gioui.org/layout"
	"gioui.org/op/clip"
	"gioui.org/op/paint"
)

const (
	colorBuckets = 8
	pickRadiusPx = 14
)

var bucketColors = func() [colorBuckets]color.NRGBA {
	stops := []color.NRGBA{{R: 0x2b, G: 0x6c, B: 0xd8, A: 0xff}, {R: 0x1f, G: 0xa8, B: 0x7a, A: 0xff}, {R: 0xe0, G: 0xb0, B: 0x1c, A: 0xff}, {R: 0xd6, G: 0x2b, B: 0x2b, A: 0xff}}
	var out [colorBuckets]color.NRGBA
	for i := range out {
		t := float64(i) / (colorBuckets - 1) * float64(len(stops)-1)
		k := int(math.Min(t, float64(len(stops)-2)))
		f := t - float64(k)
		a, b := stops[k], stops[k+1]
		mix := func(x, y uint8) uint8 { return uint8(float64(x)*(1-f) + float64(y)*f) }
		out[i] = color.NRGBA{R: mix(a.R, b.R), G: mix(a.G, b.G), B: mix(a.B, b.B), A: 0xff}
	}
	return out
}()

var (
	colBackground = color.NRGBA{R: 0xfa, G: 0xfa, B: 0xf7, A: 0xff}
	colGhost      = color.NRGBA{R: 0xb8, G: 0xb8, B: 0xb8, A: 0xff}
	colMoment     = color.NRGBA{R: 0x80, G: 0x2a, B: 0xa8, A: 0xff}
	colSupport    = color.NRGBA{R: 0x33, G: 0x33, B: 0x33, A: 0xff}
	colNode       = color.NRGBA{R: 0x22, G: 0x22, B: 0x22, A: 0xff}
	colSelected   = color.NRGBA{R: 0xff, G: 0x7a, B: 0x00, A: 0xff}
)

// canvas draws the frame and handles pan, zoom, pinch and node dragging.
type canvas struct {
	size image.Point

	dragNode int // node index being dragged, or -1
	selNode  int // node highlighted
	panning  bool
	last     f32.Point
	touches  map[pointer.ID]f32.Point

	moved    bool // a node moved since the last solve
	released bool // a drag just ended: run a full solve

	buckets     [colorBuckets][]int32 // visible member indices per colour bucket
	polyMembers []int32               // scratch: members of the current bucket drawn as multi-segment polylines
}

func newCanvas() *canvas {
	return &canvas{dragNode: -1, selNode: -1, touches: map[pointer.ID]f32.Point{}}
}

func (c *canvas) toScreen(v view, x, y float64) f32.Point {
	return f32.Point{X: float32(float64(c.size.X)/2 + (x-v.cx)*v.zoom), Y: float32(float64(c.size.Y)/2 - (y-v.cy)*v.zoom)}
}

func (c *canvas) toWorld(v view, p f32.Point) (float64, float64) {
	return v.cx + (float64(p.X)-float64(c.size.X)/2)/v.zoom, v.cy - (float64(p.Y)-float64(c.size.Y)/2)/v.zoom
}

// zoomAt zooms by factor keeping the world point under p fixed.
func (c *canvas) zoomAt(s *state, p f32.Point, factor float64) {
	wx, wy := c.toWorld(s.v, p)
	s.v.zoom = math.Min(math.Max(s.v.zoom*factor, 1e-3), 1e5)
	s.v.cx = wx - (float64(p.X)-float64(c.size.X)/2)/s.v.zoom
	s.v.cy = wy + (float64(p.Y)-float64(c.size.Y)/2)/s.v.zoom
}

func (c *canvas) pick(s *state, p f32.Point) int {
	if s.model == nil {
		return -1
	}
	best, bestD := -1, float32(pickRadiusPx*pickRadiusPx)
	for i, n := range s.model.Nodes {
		q := c.toScreen(s.v, n.X, n.Y)
		dx, dy := q.X-p.X, q.Y-p.Y
		if d := dx*dx + dy*dy; d <= bestD {
			best, bestD = i, d
		}
	}
	return best
}

func (c *canvas) handleEvents(gtx layout.Context, s *state) {
	for {
		ev, ok := gtx.Event(pointer.Filter{
			Target:  c,
			Kinds:   pointer.Press | pointer.Drag | pointer.Release | pointer.Cancel | pointer.Scroll,
			ScrollY: pointer.ScrollRange{Min: -2000, Max: 2000},
		})
		if !ok {
			return
		}
		e, ok := ev.(pointer.Event)
		if !ok {
			continue
		}
		switch e.Kind {
		case pointer.Scroll:
			c.zoomAt(s, e.Position, math.Exp(-float64(e.Scroll.Y)*0.0015))
		case pointer.Press:
			if e.Source == pointer.Touch {
				c.touches[e.PointerID] = e.Position
				if len(c.touches) == 2 {
					c.endDrag()
					c.panning = false
					continue
				}
			} else if e.Buttons != pointer.ButtonPrimary {
				continue
			}
			c.last = e.Position
			if n := c.pick(s, e.Position); n >= 0 {
				c.dragNode, c.selNode = n, n
			} else {
				c.panning = true
			}
		case pointer.Drag:
			if e.Source == pointer.Touch {
				if len(c.touches) == 2 {
					c.pinch(s, e)
					continue
				}
				c.touches[e.PointerID] = e.Position
			}
			switch {
			case c.dragNode >= 0:
				wx, wy := c.toWorld(s.v, e.Position)
				s.model.Nodes[c.dragNode].X, s.model.Nodes[c.dragNode].Y = wx, wy
				c.moved = true
			case c.panning:
				s.v.cx -= float64(e.Position.X-c.last.X) / s.v.zoom
				s.v.cy += float64(e.Position.Y-c.last.Y) / s.v.zoom
			}
			c.last = e.Position
		case pointer.Release, pointer.Cancel:
			delete(c.touches, e.PointerID)
			c.endDrag()
			c.panning = false
		}
	}
}

func (c *canvas) endDrag() {
	if c.dragNode >= 0 {
		c.released = true
	}
	c.dragNode = -1
}

// pinch zooms and pans using the two active touches.
func (c *canvas) pinch(s *state, e pointer.Event) {
	var ids [2]pointer.ID
	n := 0
	for id := range c.touches {
		if n < 2 {
			ids[n] = id
			n++
		}
	}
	oldA, oldB := c.touches[ids[0]], c.touches[ids[1]]
	c.touches[e.PointerID] = e.Position
	newA, newB := c.touches[ids[0]], c.touches[ids[1]]
	od, nd := oldA.Sub(oldB), newA.Sub(newB)
	oldLen := math.Hypot(float64(od.X), float64(od.Y))
	newLen := math.Hypot(float64(nd.X), float64(nd.Y))
	if oldLen < 1 || newLen < 1 {
		return
	}
	mid := newA.Add(newB).Mul(0.5)
	oldMid := oldA.Add(oldB).Mul(0.5)
	s.v.cx -= float64(mid.X-oldMid.X) / s.v.zoom
	s.v.cy += float64(mid.Y-oldMid.Y) / s.v.zoom
	c.zoomAt(s, mid, newLen/oldLen)
}

// layout draws the canvas filling the available space.
func (c *canvas) layout(gtx layout.Context, s *state, afterEvents func()) layout.Dimensions {
	size := gtx.Constraints.Max
	c.size = size
	defer clip.Rect{Max: size}.Push(gtx.Ops).Pop()
	event.Op(gtx.Ops, c)
	c.handleEvents(gtx, s)
	afterEvents()
	paint.Fill(gtx.Ops, colBackground)
	c.draw(gtx, s)
	return layout.Dimensions{Size: size}
}

func (c *canvas) visible(p0, p1 f32.Point, margin float32) bool {
	w, h := float32(c.size.X), float32(c.size.Y)
	return !((p0.X < -margin && p1.X < -margin) || (p0.X > w+margin && p1.X > w+margin) ||
		(p0.Y < -margin && p1.Y < -margin) || (p0.Y > h+margin && p1.Y > h+margin))
}

func (c *canvas) draw(gtx layout.Context, s *state) {
	if s.sol == nil || s.model == nil {
		return
	}
	sol := s.sol
	ci, cs := s.current()
	nodes := s.model.Nodes
	if len(nodes) != len(sol.Nodes) || cs == nil {
		return
	}

	// Pass 1: cull and bucket members.
	for b := range c.buckets {
		c.buckets[b] = c.buckets[b][:0]
	}
	hasM := s.maxM > 0 && len(s.memMaxM) == len(sol.Members)
	margin := float32(60)
	for k := range sol.Members {
		a, b := nodes[sol.MemI[k]], nodes[sol.MemJ[k]]
		if !c.visible(c.toScreen(s.v, a.X, a.Y), c.toScreen(s.v, b.X, b.Y), margin) {
			continue
		}
		bk := 0
		if hasM {
			bk = int(s.memMaxM[k] / s.maxM * (colorBuckets - 1))
			if bk >= colorBuckets {
				bk = colorBuckets - 1
			}
		}
		c.buckets[bk] = append(c.buckets[bk], int32(k))
	}

	// Ghost (undeformed) members.
	if s.showDeflect {
		var p clip.Path
		p.Begin(gtx.Ops)
		for _, ks := range c.buckets {
			for _, k := range ks {
				a, b := nodes[sol.MemI[k]], nodes[sol.MemJ[k]]
				addSegment(&p, c.toScreen(s.v, a.X, a.Y), c.toScreen(s.v, b.X, b.Y), 0.5)
			}
		}
		paint.FillShape(gtx.Ops, colGhost, clip.Outline{Path: p.End()}.Op())
	}

	// Members, coloured by max |M|; deflected when requested.
	scale := s.deflScale()
	for b, ks := range c.buckets {
		if len(ks) == 0 {
			continue
		}
		// Straight segments (undeformed members, and deflected ones too short to bend visibly) are
		// filled as thin quads, which is what a flat-capped stroke of one segment is, without the
		// stroker. Members drawn as multi-segment polylines keep the stroke, for its joins.
		var p clip.Path
		p.Begin(gtx.Ops)
		poly := c.polyMembers[:0]
		for _, k := range ks {
			a, bn := nodes[sol.MemI[k]], nodes[sol.MemJ[k]]
			if s.showDeflect && c.deflectSegments(sol.MemL[k], s.v.zoom) > 1 {
				poly = append(poly, k)
				continue
			}
			if s.showDeflect {
				c.straightDeflected(&p, s, cs, int(k), scale)
				continue
			}
			addSegment(&p, c.toScreen(s.v, a.X, a.Y), c.toScreen(s.v, bn.X, bn.Y), 1)
		}
		paint.FillShape(gtx.Ops, bucketColors[b], clip.Outline{Path: p.End()}.Op())
		c.polyMembers = poly
		if len(poly) > 0 {
			var sp clip.Path
			sp.Begin(gtx.Ops)
			for _, k := range poly {
				c.deflected(&sp, s, cs, int(k), scale)
			}
			paint.FillShape(gtx.Ops, bucketColors[b], clip.Stroke{Path: sp.End(), Width: 2}.Op())
		}
	}

	// Moment diagram.
	if s.showMoment && s.maxM > 0 {
		pxPerNm := 0.3 * s.avgLen() * s.v.zoom / s.maxM
		var p clip.Path
		p.Begin(gtx.Ops)
		for _, ks := range c.buckets {
			for _, k := range ks {
				c.momentPoly(&p, s, cs, int(k), pxPerNm)
			}
		}
		paint.FillShape(gtx.Ops, colMoment, clip.Outline{Path: p.End()}.Op())
	}
	_ = ci

	c.drawSupportsAndNodes(gtx, s)
}

// deflectSegments is the number of straight pieces a deflected member of length L (m) is drawn with.
func (c *canvas) deflectSegments(L, zoom float64) int {
	switch l := L * zoom; {
	case l > 60:
		return 8
	case l > 16:
		return 4
	}
	return 1
}

// straightDeflected appends the one-piece deflected member k as a thin quad: its end points moved by the
// (scaled) nodal displacements, which is exactly what the n == 1 case of deflected draws.
func (c *canvas) straightDeflected(p *clip.Path, s *state, cs *engineCase, k int, scale float64) {
	sol := s.sol
	i, j := int(sol.MemI[k]), int(sol.MemJ[k])
	a, b := s.model.Nodes[i], s.model.Nodes[j]
	L := sol.MemL[k]
	cx, sx := (b.X-a.X)/L, (b.Y-a.Y)/L
	d := cs.Disp
	ui, vi := cx*d[3*i]+sx*d[3*i+1], -sx*d[3*i]+cx*d[3*i+1]
	uj, vj := cx*d[3*j]+sx*d[3*j+1], -sx*d[3*j]+cx*d[3*j+1]
	p0 := c.toScreen(s.v, a.X+scale*(ui*cx-vi*sx), a.Y+scale*(ui*sx+vi*cx))
	p1 := c.toScreen(s.v, b.X+scale*(uj*cx-vj*sx), b.Y+scale*(uj*sx+vj*cx))
	addSegment(p, p0, p1, 1)
}

// addSegment appends a flat-capped line of half-width hw from a to b as a closed quad. All quads wind the
// same way, so overlaps stay filled under the non-zero rule.
func addSegment(p *clip.Path, a, b f32.Point, hw float32) {
	dx, dy := b.X-a.X, b.Y-a.Y
	l := float32(math.Hypot(float64(dx), float64(dy)))
	if l == 0 {
		return
	}
	nx, ny := -dy/l*hw, dx/l*hw
	p.MoveTo(f32.Point{X: a.X + nx, Y: a.Y + ny})
	p.LineTo(f32.Point{X: b.X + nx, Y: b.Y + ny})
	p.LineTo(f32.Point{X: b.X - nx, Y: b.Y - ny})
	p.LineTo(f32.Point{X: a.X - nx, Y: a.Y - ny})
	p.Close()
}

// deflected appends member k's deflected shape (Hermite cubic transverse, linear axial) to p.
func (c *canvas) deflected(p *clip.Path, s *state, cs *engineCase, k int, scale float64) {
	sol := s.sol
	i, j := int(sol.MemI[k]), int(sol.MemJ[k])
	a, b := s.model.Nodes[i], s.model.Nodes[j]
	L := sol.MemL[k]
	cx, sx := (b.X-a.X)/L, (b.Y-a.Y)/L
	d := cs.Disp
	ui, vi := cx*d[3*i]+sx*d[3*i+1], -sx*d[3*i]+cx*d[3*i+1]
	uj, vj := cx*d[3*j]+sx*d[3*j+1], -sx*d[3*j]+cx*d[3*j+1]
	ti, tj := d[3*i+2], d[3*j+2]
	n := c.deflectSegments(L, s.v.zoom)
	for st := 0; st <= n; st++ {
		xi := float64(st) / float64(n)
		u := ui + (uj-ui)*xi
		v := (1-3*xi*xi+2*xi*xi*xi)*vi + (xi-2*xi*xi+xi*xi*xi)*L*ti + (3*xi*xi-2*xi*xi*xi)*vj + (-xi*xi+xi*xi*xi)*L*tj
		x := a.X + (b.X-a.X)*xi + scale*(u*cx-v*sx)
		y := a.Y + (b.Y-a.Y)*xi + scale*(u*sx+v*cx)
		pt := c.toScreen(s.v, x, y)
		if st == 0 {
			p.MoveTo(pt)
		} else {
			p.LineTo(pt)
		}
	}
}

// momentPoly appends member k's moment diagram, drawn on the tension side, as thin quads (one per piece
// of the outline: axis to first station, the diagram polyline, last station back to the axis).
func (c *canvas) momentPoly(p *clip.Path, s *state, cs *engineCase, k int, pxPerNm float64) {
	sol := s.sol
	a, b := s.model.Nodes[sol.MemI[k]], s.model.Nodes[sol.MemJ[k]]
	L := sol.MemL[k]
	cx, sx := (b.X-a.X)/L, (b.Y-a.Y)/L
	p0, p1 := c.toScreen(s.v, a.X, a.Y), c.toScreen(s.v, b.X, b.Y)
	ef := cs.EndForces[6*k : 6*k+6]
	// Level of detail: diagrams on members shorter than 12 px are unreadable, so skip them;
	// below 40 px use three stations instead of eleven.
	if L*s.v.zoom < 12 {
		return
	}
	step := 1
	if L*s.v.zoom < 40 {
		step = 5
	}
	prev := p0
	at := func(st int) f32.Point {
		m := stationM(ef, cs.W[k], L, st)
		f := float32(st) / (stationCount - 1)
		off := f32.Point{X: float32(sx * m * pxPerNm), Y: float32(cx * m * pxPerNm)}
		return p0.Add(p1.Sub(p0).Mul(f)).Add(off)
	}
	for st := 0; st < stationCount; st += step {
		q := at(st)
		addSegment(p, prev, q, 0.5)
		prev = q
	}
	if step != 1 {
		q := at(stationCount - 1)
		addSegment(p, prev, q, 0.5)
		prev = q
	}
	addSegment(p, prev, p1, 0.5)
}

func (c *canvas) drawSupportsAndNodes(gtx layout.Context, s *state) {
	nodes := s.model.Nodes
	sup := s.sol.Supports
	w, h := float32(c.size.X), float32(c.size.Y)
	var p clip.Path
	p.Begin(gtx.Ops)
	any := false
	for i := range nodes {
		if !(sup[3*i] || sup[3*i+1] || sup[3*i+2]) {
			continue
		}
		q := c.toScreen(s.v, nodes[i].X, nodes[i].Y)
		if q.X < -20 || q.X > w+20 || q.Y < -20 || q.Y > h+20 {
			continue
		}
		any = true
		p.MoveTo(q)
		p.LineTo(f32.Point{X: q.X - 6, Y: q.Y + 10})
		p.LineTo(f32.Point{X: q.X + 6, Y: q.Y + 10})
		p.Close()
	}
	spec := p.End()
	if any {
		paint.FillShape(gtx.Ops, colSupport, clip.Outline{Path: spec}.Op())
	}

	if s.v.zoom*s.avgLen() >= 14 {
		var np clip.Path
		np.Begin(gtx.Ops)
		for i := range nodes {
			q := c.toScreen(s.v, nodes[i].X, nodes[i].Y)
			if q.X < -4 || q.X > w+4 || q.Y < -4 || q.Y > h+4 {
				continue
			}
			addRect(&np, q, 2.5)
		}
		paint.FillShape(gtx.Ops, colNode, clip.Outline{Path: np.End()}.Op())
	}
	if c.selNode >= 0 && c.selNode < len(nodes) {
		var sp clip.Path
		sp.Begin(gtx.Ops)
		addRect(&sp, c.toScreen(s.v, nodes[c.selNode].X, nodes[c.selNode].Y), 6)
		paint.FillShape(gtx.Ops, colSelected, clip.Outline{Path: sp.End()}.Op())
	}
}

func addRect(p *clip.Path, q f32.Point, r float32) {
	p.MoveTo(f32.Point{X: q.X - r, Y: q.Y - r})
	p.LineTo(f32.Point{X: q.X + r, Y: q.Y - r})
	p.LineTo(f32.Point{X: q.X + r, Y: q.Y + r})
	p.LineTo(f32.Point{X: q.X - r, Y: q.Y + r})
	p.Close()
}
