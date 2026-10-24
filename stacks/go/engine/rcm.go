package engine

import "sort"

// graph is a node adjacency structure in CSR form. Node indices follow ascending id.
type graph struct {
	start []int32
	adj   []int32
}

func (g *graph) degree(n int32) int32 { return g.start[n+1] - g.start[n] }

func (g *graph) neighbors(n int32) []int32 { return g.adj[g.start[n]:g.start[n+1]] }

// buildGraph makes the member adjacency with duplicate edges removed.
func buildGraph(nn int, edges [][2]int32) *graph {
	cnt := make([]int32, nn+1)
	for _, e := range edges {
		if e[0] == e[1] {
			continue
		}
		cnt[e[0]+1]++
		cnt[e[1]+1]++
	}
	for i := 0; i < nn; i++ {
		cnt[i+1] += cnt[i]
	}
	adj := make([]int32, cnt[nn])
	fill := make([]int32, nn)
	for _, e := range edges {
		if e[0] == e[1] {
			continue
		}
		a, b := e[0], e[1]
		adj[cnt[a]+fill[a]] = b
		fill[a]++
		adj[cnt[b]+fill[b]] = a
		fill[b]++
	}
	// sort and dedupe each list, compacting in place
	start := make([]int32, nn+1)
	w := int32(0)
	for n := 0; n < nn; n++ {
		l := adj[cnt[n]:cnt[n+1]]
		sort.Slice(l, func(i, j int) bool { return l[i] < l[j] })
		start[n] = w
		for i, v := range l {
			if i == 0 || v != l[i-1] {
				adj[w] = v
				w++
			}
		}
	}
	start[nn] = w
	return &graph{start: start, adj: adj[:w]}
}

// rcmOrder returns the deterministic reverse Cuthill-McKee ordering (SPEC 4.4):
// order[k] is the node index placed k-th.
func rcmOrder(g *graph) []int32 {
	nn := len(g.start) - 1
	order := make([]int32, 0, nn)
	visited := make([]bool, nn)
	mark := make([]int32, nn) // BFS stamps for level structures
	stamp := int32(0)
	queue := make([]int32, 0, nn)
	levelStart := make([]int, 0, 64)

	// levels runs a BFS from root; it leaves the visit order in queue and the level boundaries
	// in levelStart, and returns the eccentricity.
	levels := func(root int32) int {
		stamp++
		queue = append(queue[:0], root)
		levelStart = append(levelStart[:0], 0)
		mark[root] = stamp
		head := 0
		for head < len(queue) {
			end := len(queue)
			for ; head < end; head++ {
				for _, v := range g.neighbors(queue[head]) {
					if mark[v] != stamp {
						mark[v] = stamp
						queue = append(queue, v)
					}
				}
			}
			if len(queue) > end {
				levelStart = append(levelStart, end)
			}
		}
		return len(levelStart) - 1
	}
	// minDegree picks the lowest (degree, id) node in nodes.
	minDegree := func(nodes []int32) int32 {
		best := nodes[0]
		for _, v := range nodes[1:] {
			if dv, db := g.degree(v), g.degree(best); dv < db || (dv == db && v < best) {
				best = v
			}
		}
		return best
	}

	for seed := int32(0); int(seed) < nn; seed++ { // ascending min node id of each component
		if visited[seed] {
			continue
		}
		levels(seed)
		root := minDegree(queue)
		ecc := levels(root)
		for {
			cand := minDegree(queue[levelStart[len(levelStart)-1]:])
			candEcc := levels(cand)
			if candEcc > ecc {
				root, ecc = cand, candEcc
				continue
			}
			break
		}
		// Cuthill-McKee BFS from root
		first := len(order)
		order = append(order, root)
		visited[root] = true
		for head := first; head < len(order); head++ {
			from := len(order)
			for _, v := range g.neighbors(order[head]) {
				if !visited[v] {
					visited[v] = true
					order = append(order, v)
				}
			}
			nb := order[from:]
			sort.Slice(nb, func(i, j int) bool {
				di, dj := g.degree(nb[i]), g.degree(nb[j])
				return di < dj || (di == dj && nb[i] < nb[j])
			})
		}
	}
	for i, j := 0, len(order)-1; i < j; i, j = i+1, j-1 {
		order[i], order[j] = order[j], order[i]
	}
	return order
}
