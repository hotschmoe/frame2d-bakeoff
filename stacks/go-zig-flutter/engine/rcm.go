package engine

import "sort"

// buildAdjacency returns, per node index, the sorted unique neighbour indices.
func buildAdjacency(n int, edges [][2]int) [][]int {
	adj := make([][]int, n)
	for _, e := range edges {
		if e[0] == e[1] {
			continue
		}
		adj[e[0]] = append(adj[e[0]], e[1])
		adj[e[1]] = append(adj[e[1]], e[0])
	}
	for i := range adj {
		a := adj[i]
		sort.Ints(a)
		out := a[:0]
		for k, v := range a {
			if k == 0 || v != a[k-1] {
				out = append(out, v)
			}
		}
		adj[i] = out
	}
	return adj
}

// rcmOrder returns the deterministic reverse Cuthill-McKee ordering (SPEC 4.4) as node indices.
// Node indices are ordered by node id, so index order doubles as the id tie-break.
func rcmOrder(adj [][]int) []int {
	n := len(adj)
	deg := func(v int) int { return len(adj[v]) }
	visited := make([]bool, n) // component discovery
	placed := make([]bool, n)  // in the CM order
	order := make([]int, 0, n)

	// bfsLevels returns the last level and the eccentricity of the BFS rooted at r (restricted to unplaced nodes).
	mark := make([]int, n)
	stamp := 0
	bfsLast := func(r int) (last []int, ecc int) {
		stamp++
		mark[r] = stamp
		level := []int{r}
		for {
			var next []int
			for _, v := range level {
				for _, w := range adj[v] {
					if mark[w] != stamp {
						mark[w] = stamp
						next = append(next, w)
					}
				}
			}
			if len(next) == 0 {
				return level, ecc
			}
			level = next
			ecc++
		}
	}
	minDeg := func(vs []int) int {
		best := vs[0]
		for _, v := range vs[1:] {
			if deg(v) < deg(best) || (deg(v) == deg(best) && v < best) {
				best = v
			}
		}
		return best
	}

	for s := 0; s < n; s++ { // ascending min node id of each component
		if visited[s] {
			continue
		}
		// collect the component
		comp := []int{s}
		visited[s] = true
		for k := 0; k < len(comp); k++ {
			for _, w := range adj[comp[k]] {
				if !visited[w] {
					visited[w] = true
					comp = append(comp, w)
				}
			}
		}
		root := minDeg(comp)
		_, ecc := bfsLast(root)
		for {
			last, _ := bfsLast(root)
			cand := minDeg(last)
			_, e2 := bfsLast(cand)
			if e2 > ecc {
				root, ecc = cand, e2
			} else {
				break
			}
		}
		// Cuthill-McKee BFS
		start := len(order)
		order = append(order, root)
		placed[root] = true
		for k := start; k < len(order); k++ {
			v := order[k]
			var nb []int
			for _, w := range adj[v] {
				if !placed[w] {
					nb = append(nb, w)
				}
			}
			sort.Slice(nb, func(a, b int) bool {
				if deg(nb[a]) != deg(nb[b]) {
					return deg(nb[a]) < deg(nb[b])
				}
				return nb[a] < nb[b]
			})
			for _, w := range nb {
				placed[w] = true
				order = append(order, w)
			}
		}
	}
	for i, j := 0, len(order)-1; i < j; i, j = i+1, j-1 {
		order[i], order[j] = order[j], order[i]
	}
	return order
}
