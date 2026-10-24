//! Deterministic reverse Cuthill-McKee ordering (SPEC 4.4).

/// Returns node indices in final (reversed Cuthill-McKee) order.
///
/// `ids[n]` is the user-visible node id (used for tie-breaking), `edges` are member end pairs as node indices.
/// Duplicate edges and self loops are ignored.
pub fn reverse_cuthill_mckee(ids: &[i64], edges: &[(usize, usize)]) -> Vec<usize> {
    let n = ids.len();
    let adj = build_adjacency(n, edges);
    let key = |v: usize| (adj[v].len(), ids[v]);

    // Nodes in ascending id order; components are discovered in that order, so they come out
    // sorted by minimum node id.
    let mut by_id: Vec<usize> = (0..n).collect();
    by_id.sort_by_key(|&v| ids[v]);

    let mut comp_seen = vec![false; n];
    let mut bfs = LevelBfs::new(n);
    let mut visited = vec![false; n];
    let mut order = Vec::with_capacity(n);

    for &seed in &by_id {
        if comp_seen[seed] {
            continue;
        }
        // Component membership.
        let mut comp = vec![seed];
        comp_seen[seed] = true;
        let mut head = 0;
        while head < comp.len() {
            let u = comp[head];
            head += 1;
            for &v in &adj[u] {
                if !comp_seen[v] {
                    comp_seen[v] = true;
                    comp.push(v);
                }
            }
        }

        // George-Liu pseudo-peripheral node search.
        let mut start = *comp.iter().min_by_key(|&&v| key(v)).unwrap();
        let mut depth = bfs.run(&adj, start);
        loop {
            let candidate = bfs.last_level().iter().copied().min_by_key(|&v| key(v)).unwrap();
            let cand_depth = bfs.run(&adj, candidate);
            if cand_depth > depth {
                start = candidate;
                depth = cand_depth;
            } else {
                break;
            }
        }

        // Cuthill-McKee breadth-first numbering.
        let first = order.len();
        order.push(start);
        visited[start] = true;
        let mut head = first;
        let mut nbrs: Vec<usize> = Vec::new();
        while head < order.len() {
            let u = order[head];
            head += 1;
            nbrs.clear();
            nbrs.extend(adj[u].iter().copied().filter(|&v| !visited[v]));
            nbrs.sort_by_key(|&v| key(v));
            for &v in &nbrs {
                visited[v] = true;
                order.push(v);
            }
        }
    }
    order.reverse();
    order
}

fn build_adjacency(n: usize, edges: &[(usize, usize)]) -> Vec<Vec<usize>> {
    let mut adj = vec![Vec::new(); n];
    for &(a, b) in edges {
        if a != b {
            adj[a].push(b);
            adj[b].push(a);
        }
    }
    for list in &mut adj {
        list.sort_unstable();
        list.dedup();
    }
    adj
}

/// Rooted level structure with a reusable stamp array.
struct LevelBfs {
    stamp: Vec<u32>,
    epoch: u32,
    queue: Vec<usize>,
    level_start: Vec<usize>,
}

impl LevelBfs {
    fn new(n: usize) -> Self {
        LevelBfs { stamp: vec![0; n], epoch: 0, queue: Vec::new(), level_start: Vec::new() }
    }

    /// Runs a BFS from `root`; returns the number of levels.
    fn run(&mut self, adj: &[Vec<usize>], root: usize) -> usize {
        self.epoch += 1;
        self.queue.clear();
        self.level_start.clear();
        self.queue.push(root);
        self.stamp[root] = self.epoch;
        self.level_start.push(0);
        let mut level_end = 1;
        let mut head = 0;
        while head < self.queue.len() {
            if head == level_end {
                self.level_start.push(head);
                level_end = self.queue.len();
            }
            let u = self.queue[head];
            head += 1;
            for &v in &adj[u] {
                if self.stamp[v] != self.epoch {
                    self.stamp[v] = self.epoch;
                    self.queue.push(v);
                }
            }
        }
        self.level_start.len()
    }

    fn last_level(&self) -> &[usize] {
        &self.queue[*self.level_start.last().unwrap()..]
    }
}
