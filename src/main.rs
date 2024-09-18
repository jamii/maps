// extracted from the fnv crate for minor, mostly
// compile-time optimizations.
#[allow(missing_copy_implementations)]
pub struct Hasher(u64);

impl Default for Hasher {
    #[inline]
    fn default() -> Hasher {
        Hasher(0xcbf29ce484222325)
    }
}

impl std::hash::Hasher for Hasher {
    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }

    #[inline]
    #[allow(clippy::cast_lossless)]
    fn write(&mut self, bytes: &[u8]) {
        let Hasher(mut hash) = *self;

        for byte in bytes.iter() {
            hash ^= *byte as u64;
            hash = hash.wrapping_mul(0x100000001b3);
        }

        *self = Hasher(hash);
    }
}

#[allow(unused)]
type FastMap8<K, V> = std::collections::HashMap<K, V, std::hash::BuildHasherDefault<Hasher>>;

pub struct XorShift64 {
    a: u64,
}

impl XorShift64 {
    pub fn next(&mut self) -> u64 {
        let mut x = self.a;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.a = x;
        x
    }
}

fn main() {
    const N: u64 = 10_000_000;

    println!();
    println!("BTreeMap:");
    let mut btree = std::collections::BTreeMap::new();

    let writes = std::time::Instant::now();
    let mut rng = XorShift64 { a: 123456789 };
    for _ in 0_u64..N {
        let k = rng.next();
        //println!("{}", k);
        assert!(btree.insert(k, k).is_none());
    }
    dbg!(writes.elapsed());

    let reads = std::time::Instant::now();
    let mut rng = XorShift64 { a: 123456789 };
    for _ in 0_u64..N {
        let k = rng.next();
        assert_eq!(btree.get(&k), Some(&k));
    }
    dbg!(reads.elapsed());

    let scan = std::time::Instant::now();
    assert_eq!(btree.iter().map(|(bs,_)| bs).sum::<u64>(), 15738135167178238445);
    println!("full scan took {:?}", scan.elapsed());

    println!();
    println!("HashMap (sip):");
    let mut hash = std::collections::HashMap::<u64,u64>::default();

    let writes = std::time::Instant::now();
    let mut rng = XorShift64 { a: 123456789 };
    for _ in 0_u64..N {
        let k = rng.next();
        //println!("{}", k);
        assert!(hash.insert(k, k).is_none());
    }
    dbg!(writes.elapsed());

    let reads = std::time::Instant::now();
    let mut rng = XorShift64 { a: 123456789 };
    for _ in 0_u64..N {
        let k = rng.next();
        assert_eq!(hash.get(&k), Some(&k));
    }
    dbg!(reads.elapsed());

    let scan = std::time::Instant::now();
    assert_eq!(hash.iter().map(|(bs,_)| bs).sum::<u64>(), 15738135167178238445);
    println!("full scan took {:?}", scan.elapsed());

    println!();
    println!("HashMap (fnv):");
    let mut hash = FastMap8::default();

    let writes = std::time::Instant::now();
    let mut rng = XorShift64 { a: 123456789 };
    for _ in 0_u64..N {
        let k = rng.next();
        //println!("{}", k);
        assert!(hash.insert(k, k).is_none());
    }
    dbg!(writes.elapsed());

    let reads = std::time::Instant::now();
    let mut rng = XorShift64 { a: 123456789 };
    for _ in 0_u64..N {
        let k = rng.next();
        assert_eq!(hash.get(&k), Some(&k));
    }
    dbg!(reads.elapsed());

    let scan = std::time::Instant::now();
    assert_eq!(hash.iter().map(|(bs,_)| bs).sum::<u64>(), 15738135167178238445);
    println!("full scan took {:?}", scan.elapsed());
}
