#[inline]
fn rdtscp() -> u64 {
    let mut aux = 0;
    unsafe { core::arch::x86_64::__rdtscp(&mut aux) }
}

#[derive(Clone, Debug)]
struct Bin {
    min: u64,
    max: u64,
    sum: u64,
    count: u64,
}

impl Bin {
    fn new() -> Self {
        Bin {
            min: u64::MAX,
            max: 0,
            sum: 0,
            count: 0,
        }
    }

    fn add(&mut self, measurement: u64) {
        self.min = std::cmp::min(self.min, measurement);
        self.max = std::cmp::max(self.max, measurement);
        self.sum += measurement;
        self.count += 1;
    }

    fn mean(&self) -> u64 {
        return u64::div_ceil(self.sum, self.count);
    }
}

#[derive(Debug)]
struct Bins {
    bins: Vec<Bin>,
}

impl Bins {
    fn new(log_count: usize) -> Self {
        Bins {
            bins: vec![Bin::new(); log_count],
        }
    }

    fn get(&mut self, map_count: usize) -> &mut Bin {
        return &mut self.bins[(map_count as f64).log2().ceil() as usize];
    }
}

#[derive(Debug)]
struct Metrics {
    insert_miss: Bins,
    insert_hit: Bins,
    lookup_hit_all: Bins,
    lookup_miss: Bins,
    lookup_hit_one: Bins,
    free: Bins,
}

impl Metrics {
    fn new(log_count: usize) -> Self {
        Metrics {
            insert_miss: Bins::new(log_count),
            insert_hit: Bins::new(log_count),
            lookup_hit_all: Bins::new(log_count),
            lookup_miss: Bins::new(log_count),
            lookup_hit_one: Bins::new(log_count),
            free: Bins::new(log_count),
        }
    }
}

struct XorShift64 {
    a: u64,
}

impl XorShift64 {
    fn new() -> Self {
        XorShift64 { a: 123456789 }
    }

    fn next(&mut self) -> u64 {
        let mut x = self.a;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.a = x;
        x
    }
}

macro_rules! bench_one {
    ( $map:expr, $rng:expr, $log_count:expr, $metrics:expr ) => {{
        if $map.len() != 0 {
            panic!("Non-empty map");
        }

        let count = 1 << $log_count;

        let mut keys = vec![];
        for _ in 0..count {
            keys.push($rng.next());
        }

        let mut keys_missing = vec![];
        for _ in 0..count {
            keys_missing.push($rng.next());
        }

        let mut values = vec![];
        for i in 0..count {
            values.push(keys[(i + 1) % count]);
        }

        for (k, v) in std::iter::zip(&keys, &values) {
            let before = rdtscp();
            $map.insert(*k, *v);
            let after = rdtscp();
            $metrics.insert_miss.get($map.len()).add(after - before);
        }

        for (k, v) in std::iter::zip(&keys, &values) {
            let before = rdtscp();
            $map.insert(*k, *v);
            let after = rdtscp();
            $metrics.insert_hit.get($map.len()).add(after - before);
        }

        {
            let before = rdtscp();
            for k in &keys {
                let v = $map.get(k);
                if v.is_none() {
                    panic!("Oh no!")
                }
            }
            let after = rdtscp();
            $metrics
                .lookup_hit_all
                .get($map.len())
                .add((after - before) / (count as u64));
        }

        for k in &keys {
            let before = rdtscp();
            let v = $map.get(k);
            let after = rdtscp();
            $metrics.lookup_hit_one.get($map.len()).add(after - before);
            if v.is_none() {
                panic!("Oh no!")
            }
        }

        for k in &keys_missing {
            let before = rdtscp();
            let v = $map.get(k);
            let after = rdtscp();
            $metrics.lookup_miss.get($map.len()).add(after - before);
            if v.is_some() {
                panic!("Oh no!")
            }
        }
    }};
}

macro_rules! bench {
    ( $Map:ty, $rng:expr, $log_count:expr ) => {{
        let mut metrics = Metrics::new($log_count);
        for log_count_one in 0..$log_count {
            for _ in 0..(1 << ($log_count - log_count_one)) {
                let mut map = <$Map>::new();
                bench_one!(map, $rng, log_count_one, metrics);

                let len = map.len();
                let before = rdtscp();
                drop(map);
                let after = rdtscp();
                metrics.free.get(len).add(after - before);
            }
        }
        println!("insert_miss");
        print!("min =");
        for bin in &metrics.insert_miss.bins {
            print!(" {:>8}", bin.min);
        }
        println!("");
        print!("avg =");
        for bin in &metrics.insert_miss.bins {
            print!(" {:>8}", bin.mean());
        }
        println!("");
        print!("max =");
        for bin in &metrics.insert_miss.bins {
            print!(" {:>8}", bin.max);
        }
        println!("");
        println!("insert_hit");
        print!("min =");
        for bin in &metrics.insert_hit.bins {
            print!(" {:>8}", bin.min);
        }
        println!("");
        print!("avg =");
        for bin in &metrics.insert_hit.bins {
            print!(" {:>8}", bin.mean());
        }
        println!("");
        print!("max =");
        for bin in &metrics.insert_hit.bins {
            print!(" {:>8}", bin.max);
        }
        println!("");
        println!("lookup_hit_all");
        print!("min =");
        for bin in &metrics.lookup_hit_all.bins {
            print!(" {:>8}", bin.min);
        }
        println!("");
        print!("avg =");
        for bin in &metrics.lookup_hit_all.bins {
            print!(" {:>8}", bin.mean());
        }
        println!("");
        print!("max =");
        for bin in &metrics.lookup_hit_all.bins {
            print!(" {:>8}", bin.max);
        }
        println!("");
        println!("lookup_miss");
        print!("min =");
        for bin in &metrics.lookup_miss.bins {
            print!(" {:>8}", bin.min);
        }
        println!("");
        print!("avg =");
        for bin in &metrics.lookup_miss.bins {
            print!(" {:>8}", bin.mean());
        }
        println!("");
        print!("max =");
        for bin in &metrics.lookup_miss.bins {
            print!(" {:>8}", bin.max);
        }
        println!("");
        println!("lookup_hit_one");
        print!("min =");
        for bin in &metrics.lookup_hit_one.bins {
            print!(" {:>8}", bin.min);
        }
        println!("");
        print!("avg =");
        for bin in &metrics.lookup_hit_one.bins {
            print!(" {:>8}", bin.mean());
        }
        println!("");
        print!("max =");
        for bin in &metrics.lookup_hit_one.bins {
            print!(" {:>8}", bin.max);
        }
        println!("");
        println!("free");
        print!("min =");
        for bin in &metrics.free.bins {
            print!(" {:>8}", bin.min);
        }
        println!("");
        print!("avg =");
        for bin in &metrics.free.bins {
            print!(" {:>8}", bin.mean());
        }
        println!("");
        print!("max =");
        for bin in &metrics.free.bins {
            print!(" {:>8}", bin.max);
        }
        println!("");
    }};
}

fn main() {
    let log_count = 17;

    println!();

    println!("BTreeMap:");
    let mut rng = XorShift64::new();
    bench!(std::collections::BTreeMap::<u64, u64>, rng, log_count);

    println!();

    println!("HashMap (sip):");
    let mut rng = XorShift64::new();
    bench!(std::collections::HashMap::<u64, u64>, rng, log_count);

    println!();
}
