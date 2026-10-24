package engine

// Echo returns n deterministic values. It stands in for an engine result crossing a call boundary
// in the boundary bench (SPEC 5.5).
func Echo(n int) []float64 {
	out := make([]float64, n)
	for i := range out {
		out[i] = float64(i)
	}
	return out
}
