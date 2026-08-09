use gpui::{
    div, prelude::*, px, rgb, size, App, Application, Bounds, Context, SharedString, Window,
    WindowBounds, WindowOptions,
};

const WINDOW_TITLE: &str = "Wrenflow GPUI Spike";

extern "C" {
    fn wrenflow_spike_install_shell();
    fn wrenflow_spike_set_accessory_mode();
    fn wrenflow_spike_show_overlay();
    fn wrenflow_spike_hide_overlay();
}

struct SpikeView {
    overlay_visible: bool,
    microphone: SharedString,
}

impl SpikeView {
    fn new() -> Self {
        Self {
            overlay_visible: false,
            microphone: "MacBook Microphone".into(),
        }
    }
}

impl Render for SpikeView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let overlay_label = if self.overlay_visible {
            "Hide native overlay"
        } else {
            "Show native overlay"
        };

        div()
            .size_full()
            .bg(rgb(0xf5f5f7))
            .text_color(rgb(0x1d1d1f))
            .font_family("-apple-system")
            .p_8()
            .flex()
            .flex_col()
            .gap_5()
            .child(
                div()
                    .text_3xl()
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child("Wrenflow without Flutter"),
            )
            .child(div().text_sm().text_color(rgb(0x66666a)).child(
                "GPUI owns this settings window. AppKit owns tray, activation policy and overlays.",
            ))
            .child(
                div()
                    .p_4()
                    .rounded_lg()
                    .bg(rgb(0xffffff))
                    .border_1()
                    .border_color(rgb(0xd7d7da))
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(div().text_sm().child("Microphone"))
                    .child(
                        div()
                            .p_3()
                            .rounded_md()
                            .bg(rgb(0xeeeeef))
                            .child(self.microphone.clone()),
                    )
                    .child(
                        div()
                            .id("overlay-toggle")
                            .cursor_pointer()
                            .p_3()
                            .rounded_md()
                            .bg(rgb(0x2f6fed))
                            .text_color(rgb(0xffffff))
                            .child(overlay_label)
                            .on_click(cx.listener(|view, _, _, cx| {
                                view.overlay_visible = !view.overlay_visible;
                                unsafe {
                                    if view.overlay_visible {
                                        wrenflow_spike_show_overlay();
                                    } else {
                                        wrenflow_spike_hide_overlay();
                                    }
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        div()
                            .id("accessory-mode")
                            .cursor_pointer()
                            .p_3()
                            .rounded_md()
                            .bg(rgb(0xe5e5e7))
                            .child("Hide window and return to menu bar")
                            .on_click(|_, _, _| unsafe {
                                wrenflow_spike_set_accessory_mode();
                            }),
                    ),
            )
            .child(div().text_xs().text_color(rgb(0x78787c)).child(
                "Use the menu-bar bird to reopen this window, toggle the native NSPanel, or quit.",
            ))
    }
}

fn main() {
    Application::new().run(|cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(640.0), px(480.0)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(gpui::TitlebarOptions {
                    title: Some(WINDOW_TITLE.into()),
                    ..Default::default()
                }),
                ..Default::default()
            },
            |_window, cx| cx.new(|_| SpikeView::new()),
        )
        .expect("GPUI window must open");

        // GPUI initializes NSApplication in regular mode. Re-assert the menu-bar
        // lifecycle only after GPUI has created its platform application.
        unsafe { wrenflow_spike_install_shell() };
    });
}
