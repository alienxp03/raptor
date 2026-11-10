import Foundation

/// Port of Go's sort.Stable (insertionSort + symMerge). Required verbatim:
/// fuzzy.Matches sorts with the non-strict Less `a[i].Score >= a[j].Score`,
/// and equal-score ordering must match Go exactly — insertion sort with `>=`
/// reverses equal elements inside a sorted block. The comparator takes values
/// evaluated at current slice positions, like Go's Less(i, j).
func stableSortGo<T>(_ data: [T], less: (T, T) -> Bool) -> [T] {
    var out = data
    let n = out.count
    var blockSize = 20 // must be > 0
    var a = 0
    var b = blockSize
    while b <= n {
        insertionSortGo(&out, less: less, a, b)
        a = b
        b += blockSize
    }
    insertionSortGo(&out, less: less, a, n)

    while blockSize < n {
        a = 0
        b = 2 * blockSize
        while b <= n {
            symMergeGo(&out, less: less, a, a + blockSize, b)
            a = b
            b += 2 * blockSize
        }
        let m = a + blockSize
        if m < n {
            symMergeGo(&out, less: less, a, m, n)
        }
        blockSize *= 2
    }
    return out
}

func insertionSortGo<T>(_ data: inout [T], less: (T, T) -> Bool, _ a: Int, _ b: Int) {
    guard a >= 0, b <= data.count, a < b else { return }
    var i = a + 1
    while i < b {
        var j = i
        while j > a && less(data[j], data[j - 1]) {
            data.swapAt(j, j - 1)
            j -= 1
        }
        i += 1
    }
}

func swapRangeGo<T>(_ data: inout [T], _ a: Int, _ b: Int, _ n: Int) {
    var i = 0
    while i < n {
        data.swapAt(a + i, b + i)
        i += 1
    }
}

func rotateGo<T>(_ data: inout [T], _ a: Int, _ m: Int, _ b: Int) {
    var i = m - a
    var j = b - m

    while i != j {
        if i > j {
            swapRangeGo(&data, m - i, m, j)
            i -= j
        } else {
            swapRangeGo(&data, m - i, m + j - i, i)
            j -= i
        }
    }
    // i == j
    swapRangeGo(&data, m - i, m, i)
}

func symMergeGo<T>(_ data: inout [T], less: (T, T) -> Bool, _ a: Int, _ m: Int, _ b: Int) {
    // Avoid unnecessary recursions of symMerge
    // by direct insertion of data[a] into data[m:b]
    // if data[a:m] only contains one element.
    if m - a == 1 {
        // Use binary search to find the lowest index i
        // such that data[i] >= data[a] for m <= i < b.
        // Exit the search loop with i == b in case no such index exists.
        var i = m
        var j = b
        while i < j {
            let h = (i + j) >> 1
            if less(data[h], data[a]) {
                i = h + 1
            } else {
                j = h
            }
        }
        // Swap values until data[a] reaches the position before i.
        var k = a
        while k < i - 1 {
            data.swapAt(k, k + 1)
            k += 1
        }
        return
    }

    // Avoid unnecessary recursions of symMerge
    // by direct insertion of data[m] into data[a:m]
    // if data[m:b] only contains one element.
    if b - m == 1 {
        // Use binary search to find the lowest index i
        // such that data[i] > data[m] for a <= i < m.
        // Exit the search loop with i == m in case no such index exists.
        var i = a
        var j = m
        while i < j {
            let h = (i + j) >> 1
            if !less(data[m], data[h]) {
                i = h + 1
            } else {
                j = h
            }
        }
        // Swap values until data[m] reaches the position i.
        var k = m
        while k > i {
            data.swapAt(k, k - 1)
            k -= 1
        }
        return
    }

    let mid = (a + b) >> 1
    let n = mid + m
    var start: Int
    var r: Int
    if m > mid {
        start = n - b
        r = mid
    } else {
        start = a
        r = m
    }
    let p = n - 1

    while start < r {
        let c = (start + r) >> 1
        if !less(data[p - c], data[c]) {
            start = c + 1
        } else {
            r = c
        }
    }

    let end = n - start
    if start < m && m < end {
        rotateGo(&data, start, m, end)
    }
    if a < start && start < mid {
        symMergeGo(&data, less: less, a, start, mid)
    }
    if mid < end && end < b {
        symMergeGo(&data, less: less, mid, end, b)
    }
}
