use std::{collections::HashMap, ffi::c_void, hint::black_box, time::Instant};
#[repr(C)] #[derive(Default)] struct Info { start:u64, parent:u32, uid:u32, name:[u8;16] }
#[repr(C)] #[derive(Default)] struct Usage { cpu:u64, energy:u64, memory:u64 }
#[derive(Clone)] struct Reading { pid:i32, _start:u64, _parent:u32, _uid:u32, _name:String, _path:String, _cpu:Option<u64>, _energy:Option<u64>, memory:Option<u64> }
unsafe extern "C" {
    fn proc_listallpids(buffer:*mut c_void, size:i32)->i32;
    fn proc_pidpath(pid:i32, buffer:*mut c_void, size:u32)->i32;
    fn pw_bsd(pid:i32, info:*mut Info)->i32;
    fn pw_usage(pid:i32, usage:*mut Usage)->i32;
    fn pw_timebase()->f64;
    fn pw_cpu_seconds()->f64;
    fn pw_energy_supported()->i32;
    fn getpid()->i32;
}
struct Sampler { paths:HashMap<(i32,u64),String>, names:HashMap<(i32,u64),String>, timebase:f64, energy:bool }
impl Sampler {
    fn new()->Self { Self { paths:HashMap::new(), names:HashMap::new(), timebase:unsafe{pw_timebase()}, energy:unsafe{pw_energy_supported()!=0} } }
    fn sample(&mut self)->Vec<Reading> {
        let count=unsafe{proc_listallpids(std::ptr::null_mut(),0)};
        let mut pids=vec![0i32;(count.max(0) as usize+128).max(64)];
        let actual=unsafe{proc_listallpids(pids.as_mut_ptr().cast(),(pids.len()*4) as i32)};
        let mut result=Vec::new(); let mut paths=HashMap::new(); let mut names=HashMap::new();
        for &pid in pids.iter().take((actual.max(0) as usize).min(pids.len())).filter(|&&p|p>0) {
            let mut info=Info::default();
            if unsafe{pw_bsd(pid,&mut info)}==0 { continue; }
            let mut usage=Usage::default(); let available=unsafe{pw_usage(pid,&mut usage)}!=0;
            let key=(pid,info.start);
            let path=self.paths.get(&key).cloned().unwrap_or_else(|| {
                let mut bytes=[0u8;4096];
                if unsafe{proc_pidpath(pid,bytes.as_mut_ptr().cast(),bytes.len() as u32)}>0 {
                    String::from_utf8_lossy(&bytes[..bytes.iter().position(|&x|x==0).unwrap_or(bytes.len())]).into_owned()
                } else { String::new() }
            });
            let name=self.names.get(&key).cloned().unwrap_or_else(|| {
                if path.is_empty() { String::from_utf8_lossy(&info.name[..info.name.iter().position(|&x|x==0).unwrap_or(16)]).into_owned() }
                else { path.rsplit('/').next().unwrap_or("").to_owned() }
            });
            let mut after=Info::default();
            if unsafe{pw_bsd(pid,&mut after)}==0 || after.start!=info.start { continue; }
            paths.insert(key,path.clone()); if !path.is_empty() { names.insert(key,name.clone()); }
            result.push(Reading { pid,_start:info.start,_parent:info.parent,_uid:info.uid,_name:name,_path:path,
                _cpu:available.then_some((usage.cpu as f64*self.timebase) as u64),
                _energy:(available && self.energy).then_some(usage.energy),memory:available.then_some(usage.memory) });
        }
        self.paths=paths;self.names=names;result
    }
}
fn main() {
    let args:Vec<String>=std::env::args().collect();
    let iterations:usize=args.get(1).map(|x|x.parse().unwrap()).unwrap_or(300);
    let mut sampler=Sampler::new();
    for _ in 0..10 { black_box(sampler.sample()); }
    let cpu_start=unsafe{pw_cpu_seconds()};let begin=Instant::now();
    let mut count=0;let mut readable=0;let mut checksum=0u64;
    for _ in 0..iterations {
        let readings=sampler.sample();count=readings.len();readable=readings.iter().filter(|r|r._cpu.is_some()).count();
        checksum=checksum.wrapping_add(readings.iter().fold(0u64,|s,r|s.wrapping_add(r.pid as u64).wrapping_add(r.memory.unwrap_or(0))));
        black_box(readings);
    }
    let wall=begin.elapsed().as_secs_f64();let cpu=unsafe{pw_cpu_seconds()}-cpu_start;
    let mut own=Usage::default();let available=unsafe{pw_usage(getpid(),&mut own)}!=0;
    println!("{{\"language\":\"Rust\",\"mode\":\"process\",\"iterations\":{iterations},\"wall_ms_per_pass\":{},\"cpu_ms_per_pass\":{},\"processes\":{count},\"readable_processes\":{readable},\"footprint_mib\":{},\"checksum\":\"{checksum}\"}}",wall*1000.0/iterations as f64,cpu*1000.0/iterations as f64,if available{own.memory as f64/1048576.0}else{-1.0});
}
