use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use ansi_to_tui::IntoText;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph};
use ratatui::{DefaultTerminal, Frame};
use tui_big_text::{BigText, PixelSize};

enum Act {
    Inside(&'static [&'static str], bool),
    Suspend(&'static [&'static str]),
    Urls,
    Sizes,
    Edit(&'static str),
    Enroll(&'static str),
}

const ACTIONS: &[(&str, &str, Act)] = &[
    ("r", "Reconnect all devices", Act::Inside(&[], false)),
    ("n", "Connect selected device", Act::Inside(&["wifi"], true)),
    ("u", "Open a URL on the device", Act::Urls),
    ("z", "Emulate a screen size", Act::Sizes),
    ("i", "DevTools inspector bridge", Act::Inside(&["inspect"], true)),
    ("t", "Full status report", Act::Inside(&["status"], false)),
    ("c", "Screenshot", Act::Inside(&["cap"], true)),
    ("v", "Record screen (Esc stops)", Act::Inside(&["rec"], true)),
    ("l", "Live browser logs (Esc stops)", Act::Inside(&["logs"], true)),
    ("x", "Clear browser data", Act::Inside(&["clear"], true)),
    ("b", "Stop browser", Act::Inside(&["stop"], true)),
    ("e", "Enroll: USB cable", Act::Enroll("usb")),
    ("w", "Enroll: QR pairing", Act::Enroll("qr")),
    ("m", "Remove selected device", Act::Inside(&["rm"], true)),
    ("p", "Proxy: start / check", Act::Inside(&["proxy", "start"], false)),
    ("o", "Proxy: stop", Act::Inside(&["proxy", "stop"], false)),
    ("g", "Proxy: logs", Act::Inside(&["proxy", "logs"], false)),
    ("f", "Disconnect selected device", Act::Inside(&["off"], true)),
    ("s", "Disconnect everything (off)", Act::Inside(&["off"], false)),
    ("d", "Install dependencies (setup)", Act::Suspend(&["setup"])),
    ("1", "Edit urls.env", Act::Edit("urls.env")),
    ("2", "Edit devices.env", Act::Edit("devices.env")),
    ("3", "Edit proxy.env", Act::Edit("proxy.env")),
];

const SIZES: &[&str] = &[
    "phone", "phone-small", "tablet-8", "tablet-10", "fold-open", "reset",
];

type Cache = HashMap<String, String>;

struct Device {
    name: String,
    dtype: String,
    serial: String,
    link: Option<String>,
}

enum Popup {
    Urls(Vec<String>, ListState),
    Sizes(ListState),
    Device(String, ListState),
    Target(Vec<String>, ListState),
    Name(&'static str, String),
}

#[derive(PartialEq, Clone, Copy)]
enum Focus {
    Actions,
    Output,
}

struct App {
    script: PathBuf,
    dir: PathBuf,
    devices: Vec<Device>,
    cache: Cache,
    scan_rx: Option<mpsc::Receiver<(Vec<Device>, Cache)>>,
    dev_state: ListState,
    act_state: ListState,
    focus: Focus,
    output: String,
    out_rx: Option<mpsc::Receiver<String>>,
    out_scroll: Option<u16>,
    child: Option<Child>,
    popup: Option<Popup>,
}

fn find_script() -> Option<PathBuf> {
    let mut candidates = vec![PathBuf::from("tablet.sh")];
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("tablet.sh"));
            candidates.push(dir.join("..").join("..").join("tablet.sh"));
            candidates.push(dir.join("..").join("..").join("..").join("tablet.sh"));
        }
    }
    candidates
        .into_iter()
        .find(|p| p.is_file())
        .map(|p| p.canonicalize().unwrap_or(p))
}

fn registry(dir: &Path) -> Vec<Device> {
    let mut devices = Vec::new();
    if let Ok(s) = std::fs::read_to_string(dir.join("devices.env")) {
        for l in s.lines() {
            let t = l.trim();
            if t.is_empty() || t.starts_with('#') {
                continue;
            }
            let f: Vec<&str> = t.split('|').map(str::trim).collect();
            if f.len() < 2 || f[1].is_empty() {
                continue;
            }
            devices.push(Device {
                name: f[0].to_string(),
                serial: f[1].to_string(),
                dtype: f
                    .get(3)
                    .copied()
                    .filter(|v| !v.is_empty())
                    .unwrap_or("wifi")
                    .to_string(),
                link: None,
            });
        }
    }
    devices
}

fn urls(dir: &Path) -> Vec<String> {
    std::fs::read_to_string(dir.join("urls.env"))
        .map(|s| {
            s.lines()
                .map(str::trim)
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn scan(dir: &Path, cache: &mut Cache) -> Vec<Device> {
    let mut devices = registry(dir);
    if let Ok(o) = Command::new("adb").arg("devices").output() {
        for l in String::from_utf8_lossy(&o.stdout).lines().skip(1) {
            let mut it = l.split('\t');
            let (Some(id), Some(state)) = (it.next(), it.next()) else {
                continue;
            };
            if state != "device" {
                continue;
            }
            let hw = match cache.get(id) {
                Some(h) => h.clone(),
                None => {
                    let h = Command::new("adb")
                        .args(["-s", id, "shell", "getprop", "ro.serialno"])
                        .output()
                        .ok()
                        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                        .unwrap_or_default();
                    if !h.is_empty() {
                        cache.insert(id.to_string(), h.clone());
                    }
                    h
                }
            };
            for d in devices.iter_mut() {
                if d.serial == hw && d.link.is_none() {
                    d.link = Some(id.to_string());
                }
            }
        }
    }
    devices
}

fn spawn_scan(dir: PathBuf, mut cache: Cache) -> mpsc::Receiver<(Vec<Device>, Cache)> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let devices = scan(&dir, &mut cache);
        let _ = tx.send((devices, cache));
    });
    rx
}

fn editor() -> String {
    for v in ["VISUAL", "EDITOR"] {
        if let Ok(e) = std::env::var(v) {
            if !e.trim().is_empty() {
                return e;
            }
        }
    }
    for e in ["nano", "vi"] {
        let found = Command::new("sh")
            .args(["-c", &format!("command -v {e}")])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if found {
            return e.to_string();
        }
    }
    "vi".to_string()
}

fn centered(area: Rect, pw: u16, ph: u16) -> Rect {
    let w = pw.min(area.width);
    let h = ph.min(area.height);
    Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    )
}

impl App {
    fn new(script: PathBuf) -> Self {
        let dir = script.parent().unwrap_or(Path::new(".")).to_path_buf();
        let devices = registry(&dir);
        let mut dev_state = ListState::default();
        if !devices.is_empty() {
            dev_state.select(Some(0));
        }
        let mut act_state = ListState::default();
        act_state.select(Some(0));
        let scan_rx = Some(spawn_scan(dir.clone(), Cache::new()));
        Self {
            script,
            dir,
            devices,
            cache: Cache::new(),
            scan_rx,
            dev_state,
            act_state,
            focus: Focus::Actions,
            output: String::from("Welcome. Pick an action — its output shows up right here.\n"),
            out_rx: None,
            out_scroll: None,
            child: None,
            popup: None,
        }
    }

    fn refresh(&mut self) {
        if self.scan_rx.is_none() {
            self.scan_rx = Some(spawn_scan(self.dir.clone(), self.cache.clone()));
        }
    }

    fn poll_scan(&mut self) {
        let Some(rx) = &self.scan_rx else { return };
        if let Ok((devices, cache)) = rx.try_recv() {
            self.devices = devices;
            self.cache = cache;
            self.scan_rx = None;
            let sel = self.dev_state.selected().unwrap_or(0);
            if self.devices.is_empty() {
                self.dev_state.select(None);
            } else {
                self.dev_state.select(Some(sel.min(self.devices.len() - 1)));
            }
        }
    }

    fn selected_device(&self) -> Option<&Device> {
        self.dev_state.selected().and_then(|i| self.devices.get(i))
    }

    fn busy(&self) -> bool {
        self.child.is_some() || self.out_rx.is_some()
    }

    fn start_inside(&mut self, args: Vec<String>) {
        if self.busy() {
            return;
        }
        self.output = format!("$ tablet.sh {}\n", args.join(" "));
        self.out_scroll = None;
        let mut cmd = Command::new("bash");
        cmd.arg(&self.script)
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);
        match cmd.spawn() {
            Ok(mut child) => {
                let (tx, rx) = mpsc::channel::<String>();
                if let Some(out) = child.stdout.take() {
                    let tx = tx.clone();
                    std::thread::spawn(move || {
                        for l in BufReader::new(out).lines().map_while(Result::ok) {
                            if tx.send(l).is_err() {
                                break;
                            }
                        }
                    });
                }
                if let Some(err) = child.stderr.take() {
                    std::thread::spawn(move || {
                        for l in BufReader::new(err).lines().map_while(Result::ok) {
                            if tx.send(l).is_err() {
                                break;
                            }
                        }
                    });
                }
                self.child = Some(child);
                self.out_rx = Some(rx);
            }
            Err(e) => self.output.push_str(&format!("[x] failed to run tablet.sh: {e}\n")),
        }
    }

    fn poll_output(&mut self) {
        let mut done = false;
        if let Some(rx) = &self.out_rx {
            loop {
                match rx.try_recv() {
                    Ok(l) => {
                        self.output.push_str(&l);
                        self.output.push('\n');
                        if self.output.len() > 200_000 {
                            let cut = self.output.len() - 150_000;
                            let cut = self.output[cut..]
                                .find('\n')
                                .map(|i| cut + i + 1)
                                .unwrap_or(cut);
                            self.output.drain(..cut);
                        }
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        done = true;
                        break;
                    }
                }
            }
        }
        if done {
            self.out_rx = None;
            if let Some(mut child) = self.child.take() {
                let status = child.wait().ok();
                match status {
                    Some(s) if s.success() => self.output.push_str("── done ──\n"),
                    Some(s) => self.output.push_str(&format!("── done ({s}) ──\n")),
                    None => self.output.push_str("── done ──\n"),
                }
            }
            self.refresh();
        }
    }

    fn kill_child(&mut self) {
        if let Some(child) = &self.child {
            let pid = child.id();
            let _ = Command::new("sh")
                .arg("-c")
                .arg(format!("kill -INT -{pid} 2>/dev/null || kill -INT {pid} 2>/dev/null"))
                .status();
            self.output.push_str("── stop requested ──\n");
        }
    }

    fn run_suspend(&mut self, terminal: &mut DefaultTerminal, args: &[&str]) -> io::Result<()> {
        ratatui::restore();
        println!();
        match Command::new("bash").arg(&self.script).args(args).status() {
            Ok(s) if s.success() => {}
            Ok(s) => println!("  (tablet.sh exited with {s})"),
            Err(e) => println!("  [x] failed to run tablet.sh: {e}"),
        }
        println!();
        print!("  Press Enter to return to the console...");
        let _ = io::stdout().flush();
        let _ = io::stdin().read_line(&mut String::new());
        *terminal = ratatui::init();
        self.refresh();
        Ok(())
    }

    fn edit_file(&mut self, terminal: &mut DefaultTerminal, file: &str) -> io::Result<()> {
        ratatui::restore();
        let path = self.dir.join(file);
        let _ = Command::new("sh")
            .arg("-c")
            .arg(format!("{} \"$1\"", editor()))
            .arg("sh")
            .arg(&path)
            .status();
        *terminal = ratatui::init();
        self.output = format!("{file} saved — press 'r' to re-apply tunnels/proxy\n");
        self.refresh();
        Ok(())
    }

    fn execute(&mut self, terminal: &mut DefaultTerminal, idx: usize) -> io::Result<()> {
        match &ACTIONS[idx].2 {
            Act::Edit(file) => return self.edit_file(terminal, file),
            Act::Enroll(cmd) => self.popup = Some(Popup::Name(*cmd, String::new())),
            Act::Suspend(args) => {
                let args: Vec<&str> = args.to_vec();
                return self.run_suspend(terminal, &args);
            }
            Act::Urls => {
                let items = urls(&self.dir);
                if items.is_empty() {
                    self.output = "urls.env is empty — press '1' to add your URLs.\n".to_string();
                    return Ok(());
                }
                let mut st = ListState::default();
                st.select(Some(0));
                self.popup = Some(Popup::Urls(items, st));
            }
            Act::Sizes => {
                let mut st = ListState::default();
                st.select(Some(0));
                self.popup = Some(Popup::Sizes(st));
            }
            Act::Inside(args, takes_device) => {
                let full: Vec<String> = args.iter().map(|s| s.to_string()).collect();
                if *takes_device {
                    if self.devices.is_empty() {
                        self.output =
                            "no device selected — enroll one first ('e' or 'w').\n".to_string();
                        return Ok(());
                    }
                    let mut st = ListState::default();
                    st.select(Some(self.dev_state.selected().unwrap_or(0)));
                    self.popup = Some(Popup::Target(full, st));
                    return Ok(());
                }
                self.start_inside(full);
            }
        }
        Ok(())
    }

    fn popup_enter(&mut self) {
        let Some(popup) = self.popup.take() else { return };
        match popup {
            Popup::Urls(items, st) => {
                if let Some(i) = st.selected() {
                    let url = items[i].clone();
                    if self.devices.is_empty() {
                        self.output = "no devices enrolled — press 'e' or 'w'.\n".to_string();
                        return;
                    }
                    let mut ds = ListState::default();
                    ds.select(Some(self.dev_state.selected().unwrap_or(0)));
                    self.popup = Some(Popup::Device(url, ds));
                }
            }
            Popup::Device(url, st) => {
                if let Some(i) = st.selected() {
                    if let Some(d) = self.devices.get(i) {
                        let n = d.name.clone();
                        self.dev_state.select(Some(i));
                        self.start_inside(vec!["url".into(), n, url]);
                    }
                }
            }
            Popup::Sizes(st) => {
                if self.devices.is_empty() {
                    self.output =
                        "no device selected — enroll one first ('e' or 'w').\n".to_string();
                    return;
                }
                if let Some(i) = st.selected() {
                    let mut ds = ListState::default();
                    ds.select(Some(self.dev_state.selected().unwrap_or(0)));
                    self.popup =
                        Some(Popup::Target(vec!["size".into(), SIZES[i].to_string()], ds));
                }
            }
            Popup::Target(args, st) => {
                if let Some(i) = st.selected() {
                    if let Some(d) = self.devices.get(i) {
                        let n = d.name.clone();
                        self.dev_state.select(Some(i));
                        let mut full = args;
                        full.push(n);
                        self.start_inside(full);
                    }
                }
            }
            Popup::Name(cmd, buf) => {
                if buf.is_empty() {
                    self.popup = Some(Popup::Name(cmd, buf));
                    return;
                }
                self.start_inside(vec![cmd.to_string(), buf]);
            }
        }
    }

    fn run(&mut self, terminal: &mut DefaultTerminal) -> io::Result<()> {
        loop {
            self.poll_scan();
            self.poll_output();
            terminal.draw(|f| self.draw(f))?;
            if !event::poll(Duration::from_millis(100))? {
                continue;
            }
            let Event::Key(key) = event::read()? else { continue };
            if key.kind != KeyEventKind::Press {
                continue;
            }
            let ctrl_c = key.code == KeyCode::Char('c')
                && key.modifiers.contains(KeyModifiers::CONTROL);
            if let Some(Popup::Name(_, _)) = &self.popup {
                match key.code {
                    KeyCode::Esc => self.popup = None,
                    KeyCode::Enter => self.popup_enter(),
                    KeyCode::Backspace => self.name_edit(None),
                    KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                        self.name_edit(Some(c))
                    }
                    _ => {}
                }
                continue;
            }
            if self.popup.is_some() {
                match key.code {
                    KeyCode::Esc => self.popup = None,
                    KeyCode::Enter => self.popup_enter(),
                    KeyCode::Up | KeyCode::Char('k') => self.popup_step(-1),
                    KeyCode::Down | KeyCode::Char('j') => self.popup_step(1),
                    _ => {}
                }
                continue;
            }
            if key.code == KeyCode::PageUp {
                let cur = self.out_scroll.unwrap_or(u16::MAX);
                self.out_scroll = Some(cur.saturating_sub(5));
                continue;
            }
            if key.code == KeyCode::PageDown {
                if let Some(s) = self.out_scroll {
                    self.out_scroll = Some(s.saturating_add(5));
                }
                continue;
            }
            if key.code == KeyCode::End {
                self.out_scroll = None;
                continue;
            }
            if self.busy() {
                if ctrl_c || key.code == KeyCode::Esc {
                    self.kill_child();
                } else if key.code == KeyCode::Char('q') {
                    self.kill_child();
                    return Ok(());
                }
                continue;
            }
            match key.code {
                KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                KeyCode::Char('R') => self.refresh(),
                KeyCode::Tab | KeyCode::Right | KeyCode::BackTab | KeyCode::Left => {
                    self.focus = match self.focus {
                        Focus::Actions => Focus::Output,
                        Focus::Output => Focus::Actions,
                    }
                }
                KeyCode::Up | KeyCode::Char('k') => self.step(-1),
                KeyCode::Down | KeyCode::Char('j') => self.step(1),
                KeyCode::Enter => match self.focus {
                    Focus::Output => self.focus = Focus::Actions,
                    Focus::Actions => {
                        if let Some(i) = self.act_state.selected() {
                            self.execute(terminal, i)?;
                        }
                    }
                },
                KeyCode::Char(c) => {
                    if let Some(i) = ACTIONS.iter().position(|a| a.0 == c.to_string()) {
                        self.act_state.select(Some(i));
                        self.execute(terminal, i)?;
                    }
                }
                _ => {}
            }
        }
    }

    fn name_edit(&mut self, c: Option<char>) {
        if let Some(Popup::Name(_, buf)) = &mut self.popup {
            match c {
                Some(c) if c.is_ascii_alphanumeric() || c == '-' || c == '_' => buf.push(c),
                None => {
                    buf.pop();
                }
                _ => {}
            }
        }
    }

    fn popup_step(&mut self, delta: i32) {
        if let Some(popup) = &mut self.popup {
            let (state, len) = match popup {
                Popup::Urls(items, st) => (st, items.len()),
                Popup::Sizes(st) => (st, SIZES.len()),
                Popup::Device(_, st) | Popup::Target(_, st) => (st, self.devices.len()),
                Popup::Name(_, _) => return,
            };
            if len == 0 {
                return;
            }
            let cur = state.selected().unwrap_or(0) as i32;
            state.select(Some((cur + delta).rem_euclid(len as i32) as usize));
        }
    }

    fn step(&mut self, delta: i32) {
        let (state, len) = match self.focus {
            Focus::Actions => (&mut self.act_state, ACTIONS.len()),
            Focus::Output => {
                let cur = self.out_scroll.unwrap_or(u16::MAX);
                self.out_scroll = if delta < 0 {
                    Some(cur.saturating_sub(1))
                } else {
                    Some(cur.saturating_add(1))
                };
                return;
            }
        };
        if len == 0 {
            return;
        }
        let cur = state.selected().unwrap_or(0) as i32;
        state.select(Some((cur + delta).rem_euclid(len as i32) as usize));
    }

    fn draw(&mut self, f: &mut Frame) {
        let rows = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(4),
                Constraint::Length(1),
                Constraint::Min(8),
                Constraint::Length(6),
                Constraint::Length(1),
            ])
            .split(f.area());
        let banner = BigText::builder()
            .pixel_size(PixelSize::Quadrant)
            .style(Style::default().fg(Color::Cyan))
            .alignment(ratatui::layout::Alignment::Center)
            .lines(vec!["ADB Tablet".into()])
            .build();
        f.render_widget(banner, rows[0]);
        let connected = self.devices.iter().filter(|d| d.link.is_some()).count();
        let target = self
            .selected_device()
            .map(|d| d.name.clone())
            .unwrap_or_else(|| "none".to_string());
        let summary = format!(
            "{} enrolled · {} connected · target: {}{}",
            self.devices.len(),
            connected,
            target,
            if self.scan_rx.is_some() { " · scanning…" } else { "" }
        );
        f.render_widget(
            Paragraph::new(summary)
                .style(Style::default().fg(Color::Cyan))
                .alignment(ratatui::layout::Alignment::Center),
            rows[1],
        );
        let cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(58), Constraint::Percentage(42)])
            .split(rows[2]);
        self.draw_output(f, cols[0]);
        self.draw_actions(f, cols[1]);
        self.draw_devices(f, rows[3]);
        let hints = if matches!(self.popup, Some(Popup::Name(_, _))) {
            "  type a name (letters/digits/-/_) · Enter confirm · Esc cancel"
        } else if self.popup.is_some() {
            "  j/k move · Enter select · Esc cancel"
        } else if self.busy() {
            "  running… Esc/Ctrl+C stop · PgUp/PgDn scroll · q quit"
        } else {
            "  Tab/←/→ switch Actions/Output · j/k move-scroll · Enter run · hotkey = instant · q quit"
        };
        f.render_widget(
            Paragraph::new(hints).style(Style::default().fg(Color::DarkGray)),
            rows[4],
        );
        self.draw_popup(f);
    }

    fn draw_devices(&mut self, f: &mut Frame, area: Rect) {
        let scanning = self.scan_rx.is_some();
        let items: Vec<ListItem> = if self.devices.is_empty() {
            vec![ListItem::new(Line::from(Span::styled(
                "none enrolled — press 'e' (USB) or 'w' (QR)",
                Style::default().fg(Color::DarkGray),
            )))]
        } else {
            self.devices
                .iter()
                .map(|d| {
                    let (dot, style) = match d.link {
                        Some(_) => ("●", Style::default().fg(Color::Green)),
                        None => ("○", Style::default().fg(Color::DarkGray)),
                    };
                    let detail = match &d.link {
                        Some(l) => format!("via {l}"),
                        None if scanning => "checking…".to_string(),
                        None => "offline".to_string(),
                    };
                    ListItem::new(Line::from(vec![
                        Span::styled(format!("{dot} "), style),
                        Span::raw(format!("{:<14} ", d.name)),
                        Span::styled(format!("[{:<4}] ", d.dtype), Style::default().fg(Color::Cyan)),
                        Span::styled(detail, Style::default().fg(Color::DarkGray)),
                    ]))
                })
                .collect()
        };
        let list = List::new(items)
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(Color::DarkGray))
                    .title(" Devices "),
            )
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED));
        f.render_stateful_widget(list, area, &mut self.dev_state);
    }

    fn draw_actions(&mut self, f: &mut Frame, area: Rect) {
        let items: Vec<ListItem> = ACTIONS
            .iter()
            .map(|(key, label, _)| {
                ListItem::new(Line::from(vec![
                    Span::styled(format!(" {key} "), Style::default().fg(Color::Yellow)),
                    Span::raw(label.to_string()),
                ]))
            })
            .collect();
        let border = if self.focus == Focus::Actions { Color::Cyan } else { Color::DarkGray };
        let list = List::new(items)
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(border))
                    .title(" Actions "),
            )
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED));
        f.render_stateful_widget(list, area, &mut self.act_state);
    }

    fn draw_output(&mut self, f: &mut Frame, area: Rect) {
        let text: Text = self
            .output
            .as_bytes()
            .into_text()
            .unwrap_or_else(|_| Text::raw(self.output.clone()));
        let total = text.lines.len() as u16;
        let visible = area.height.saturating_sub(2);
        let max = total.saturating_sub(visible);
        let scroll = match self.out_scroll {
            Some(s) if s >= max => {
                self.out_scroll = None;
                max
            }
            Some(s) => s,
            None => max,
        };
        let title = if self.busy() {
            " Output — running… (Esc stops) "
        } else if self.out_scroll.is_some() {
            " Output — scrolled (End = follow) "
        } else {
            " Output "
        };
        let border = if self.focus == Focus::Output { Color::Cyan } else { Color::DarkGray };
        let p = Paragraph::new(text)
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(border))
                    .title(title),
            )
            .scroll((scroll, 0));
        f.render_widget(p, area);
    }

    fn draw_popup(&mut self, f: &mut Frame) {
        let Some(popup) = &mut self.popup else { return };
        if let Popup::Name(cmd, buf) = popup {
            let lines = vec![
                Line::from(format!(" {buf}▌")),
                Line::from(Span::styled(
                    format!(" runs: tablet.sh {cmd} {buf}"),
                    Style::default().fg(Color::DarkGray),
                )),
            ];
            let area = centered(f.area(), 60, 4);
            f.render_widget(Clear, area);
            f.render_widget(
                Paragraph::new(lines).block(
                    Block::default()
                        .borders(Borders::ALL)
                        .border_style(Style::default().fg(Color::Cyan))
                        .title(" Name for the new device "),
                ),
                area,
            );
            return;
        }
        let (title, items, state): (&str, Vec<ListItem>, &mut ListState) = match popup {
            Popup::Urls(urls, st) => (
                " Open which URL? ",
                urls.iter().map(|u| ListItem::new(u.clone())).collect(),
                st,
            ),
            Popup::Device(_, st) | Popup::Target(_, st) => (
                " On which device? ",
                self.devices
                    .iter()
                    .map(|d| {
                        let dot = if d.link.is_some() { "●" } else { "○" };
                        ListItem::new(format!("{dot} {}  [{}]", d.name, d.dtype))
                    })
                    .collect(),
                st,
            ),
            Popup::Sizes(st) => (
                " Emulate which screen? ",
                SIZES.iter().map(|s| ListItem::new(*s)).collect(),
                st,
            ),
            Popup::Name(_, _) => return,
        };
        let h = (items.len() as u16 + 2).min(14);
        let area = centered(f.area(), 60, h);
        f.render_widget(Clear, area);
        let list = List::new(items)
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(Color::Cyan))
                    .title(title),
            )
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED));
        f.render_stateful_widget(list, area, state);
    }
}

fn main() -> io::Result<()> {
    let Some(script) = find_script() else {
        eprintln!("  [x] tablet.sh not found. Run tablet-ui from the project directory.");
        std::process::exit(1);
    };
    let mut app = App::new(script);
    let mut terminal = ratatui::init();
    let res = app.run(&mut terminal);
    ratatui::restore();
    res
}
