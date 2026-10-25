//! Skyline (profile) storage of a symmetric matrix and its LDL^T factorization (SPEC 4.4).
//!
//! Only the upper triangle is stored, column by column. Column `j` holds rows `j - height[j] ..= j`, with the
//! diagonal last. After `factor`, entries above the diagonal hold the unit upper factor `U` (K = U^T D U) and the
//! diagonal holds `D`.

/// A pivot at or below the tolerance: the column (DOF number) and its value.
#[derive(Debug, Clone, Copy)]
pub struct BadPivot {
    pub dof: usize,
    pub value: f64,
}

pub struct Skyline<'a> {
    pub height: &'a [usize],
    pub col_start: &'a [usize],
    pub data: Vec<f64>,
}

impl<'a> Skyline<'a> {
    pub fn zeros(height: &'a [usize], col_start: &'a [usize]) -> Self {
        Skyline { height, col_start, data: vec![0.0; *col_start.last().unwrap_or(&0)] }
    }

    pub fn n(&self) -> usize {
        self.height.len()
    }

    /// Adds `v` to entry (row, col) of the upper triangle. Requires `col - height[col] <= row <= col`.
    #[inline]
    pub fn add(&mut self, row: usize, col: usize, v: f64) {
        let first = col - self.height[col];
        debug_assert!(row >= first && row <= col);
        self.data[self.col_start[col] + row - first] += v;
    }

    #[inline]
    pub fn diag(&self, j: usize) -> f64 {
        self.data[self.col_start[j] + self.height[j]]
    }

    pub fn max_diag(&self) -> f64 {
        (0..self.n()).map(|j| self.diag(j)).fold(0.0, f64::max)
    }

    /// In-place LDL^T. Fails when a pivot is not above `tolerance * max diagonal`.
    pub fn factor(&mut self) -> Result<(), BadPivot> {
        let max_diag = self.max_diag();
        let height = self.height;
        let col_start = self.col_start;
        let data = &mut self.data[..];
        for j in 0..height.len() {
            let hj = height[j];
            let mj = j - hj;
            let cj = col_start[j];
            let (done, rest) = data.split_at_mut(cj);
            let colj = &mut rest[..=hj];

            // g_ij = K_ij - sum_{k<i} U_ki g_kj, for i in the column above the diagonal.
            for i in (mj + 1)..j {
                let hi = height[i];
                let mi = i - hi;
                let lo = mi.max(mj);
                let len = i - lo;
                let ci = col_start[i] + (lo - mi);
                let s = dot(&done[ci..ci + len], &colj[lo - mj..lo - mj + len]);
                colj[i - mj] -= s;
            }

            // U_ij = g_ij / d_i ; d_j = K_jj - sum U_ij g_ij.
            let mut dj = colj[hj];
            for i in mj..j {
                let g = colj[i - mj];
                let di = done[col_start[i] + height[i]];
                let u = g / di;
                colj[i - mj] = u;
                dj -= g * u;
            }
            if !(dj > 1e-12 * max_diag) { // BENCH-EDIT:leaf
                return Err(BadPivot { dof: j, value: dj });
            }
            colj[hj] = dj;
        }
        Ok(())
    }

    /// Solves K x = b in place on a factored matrix.
    pub fn solve(&self, x: &mut [f64]) {
        let n = self.n();
        // U^T y = b (forward).
        for j in 0..n {
            let hj = self.height[j];
            let mj = j - hj;
            let cj = self.col_start[j];
            x[j] -= dot(&self.data[cj..cj + hj], &x[mj..j]);
        }
        for j in 0..n {
            x[j] /= self.diag(j);
        }
        // U x = z (backward).
        for j in (0..n).rev() {
            let hj = self.height[j];
            let mj = j - hj;
            let cj = self.col_start[j];
            let xj = x[j];
            if xj != 0.0 {
                for (xi, u) in x[mj..j].iter_mut().zip(&self.data[cj..cj + hj]) {
                    *xi -= u * xj;
                }
            }
        }
    }
}

/// Multiply-add: a fused instruction where the baseline target has one (aarch64), plain mul + add elsewhere
/// (`f64::mul_add` without hardware FMA falls back to a slow libm call, e.g. on default x86-64 and wasm32).
#[inline(always)]
fn madd(acc: f64, x: f64, y: f64) -> f64 {
    #[cfg(target_arch = "aarch64")]
    {
        x.mul_add(y, acc)
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        acc + x * y
    }
}

#[inline]
fn dot(a: &[f64], b: &[f64]) -> f64 {
    debug_assert_eq!(a.len(), b.len());
    let mut acc = [0.0f64; 8];
    let mut ca = a.chunks_exact(8);
    let mut cb = b.chunks_exact(8);
    for (x, y) in (&mut ca).zip(&mut cb) {
        for k in 0..8 {
            acc[k] = madd(acc[k], x[k], y[k]);
        }
    }
    let mut tail = 0.0;
    for (x, y) in ca.remainder().iter().zip(cb.remainder()) {
        tail = madd(tail, *x, *y);
    }
    ((acc[0] + acc[1]) + (acc[2] + acc[3])) + ((acc[4] + acc[5]) + (acc[6] + acc[7])) + tail
}
