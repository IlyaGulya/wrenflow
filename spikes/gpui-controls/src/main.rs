use gpui::{
    App, AppContext as _, Application, Context, Entity, Focusable as _, Global, IntoElement,
    ParentElement as _, Render, SharedString, Styled as _, Window, WindowBounds, WindowOptions, px,
    size,
};
use gpui_component::{
    Root,
    input::{Input, InputState},
    setting::{SettingField, SettingGroup, SettingItem, SettingPage, Settings},
    v_flex,
};
use gpui_component_assets::Assets;

struct DemoSettings {
    model_path: SharedString,
    transcription_model: SharedString,
    launch_at_login: bool,
    history_categories: [bool; 12],
}

impl Default for DemoSettings {
    fn default() -> Self {
        Self {
            model_path: "~/Library/Application Support/Wrenflow/models".into(),
            transcription_model: "whisper-turbo".into(),
            launch_at_login: true,
            history_categories: [true; 12],
        }
    }
}

impl Global for DemoSettings {}

impl DemoSettings {
    fn get(cx: &App) -> &Self {
        cx.global::<Self>()
    }

    fn get_mut(cx: &mut App) -> &mut Self {
        cx.global_mut::<Self>()
    }
}

struct ControlsSpike {
    focused_input: Entity<InputState>,
}

impl ControlsSpike {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        cx.set_global(DemoSettings::default());

        let focused_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("Keyboard focus starts here")
                .default_value("Hold Option+Space to record")
        });

        // Programmatic focus works. InputState creates a tab-stop focus handle, so
        // Tab can continue into other focusable GPUI Component controls.
        focused_input.focus_handle(cx).focus(window);

        Self { focused_input }
    }

    fn pages(&self) -> Vec<SettingPage> {
        let mut history_items = Vec::new();
        for index in 0..12 {
            history_items.push(
                SettingItem::new(
                    format!("History category {}", index + 1),
                    SettingField::switch(
                        move |cx: &App| DemoSettings::get(cx).history_categories[index],
                        move |enabled: bool, cx: &mut App| {
                            DemoSettings::get_mut(cx).history_categories[index] = enabled;
                        },
                    ),
                )
                .description("Extra rows force the settings page to exercise its virtual list and scrollbar."),
            );
        }

        vec![
            SettingPage::new("General").default_open(true).group(
                SettingGroup::new().title("Recognition").items(vec![
                    SettingItem::new(
                        "Model",
                        SettingField::dropdown(
                            vec![
                                ("whisper-turbo".into(), "Whisper Turbo".into()),
                                ("moonshine-base".into(), "Moonshine Base".into()),
                                ("parakeet-tdt".into(), "Parakeet TDT".into()),
                            ],
                            |cx: &App| DemoSettings::get(cx).transcription_model.clone(),
                            |model: SharedString, cx: &mut App| {
                                DemoSettings::get_mut(cx).transcription_model = model;
                            },
                        ),
                    )
                    .description("A dropdown/select-like control backed by typed Rust state."),
                    SettingItem::new(
                        "Model path",
                        SettingField::input(
                            |cx: &App| DemoSettings::get(cx).model_path.clone(),
                            |path: SharedString, cx: &mut App| {
                                DemoSettings::get_mut(cx).model_path = path;
                            },
                        ),
                    )
                    .description("A text input with selection, clipboard and IME support."),
                    SettingItem::new(
                        "Launch at login",
                        SettingField::switch(
                            |cx: &App| DemoSettings::get(cx).launch_at_login,
                            |enabled: bool, cx: &mut App| {
                                DemoSettings::get_mut(cx).launch_at_login = enabled;
                            },
                        ),
                    )
                    .description("A pointer-operated switch."),
                ]),
            ),
            SettingPage::new("History").default_open(true).group(
                SettingGroup::new()
                    .title("Visible categories")
                    .items(history_items),
            ),
        ]
    }
}

impl Render for ControlsSpike {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .child(
                v_flex()
                    .p_4()
                    .gap_2()
                    .child("Wrenflow GPUI controls spike")
                    .child(Input::new(&self.focused_input).tab_index(0)),
            )
            .child(Settings::new("wrenflow-settings").pages(self.pages()))
    }
}

fn main() {
    Application::new().with_assets(Assets).run(|cx| {
        gpui_component::init(cx);

        let options = WindowOptions {
            window_bounds: Some(WindowBounds::centered(size(px(820.), px(560.)), cx)),
            ..Default::default()
        };

        cx.spawn(async move |cx| {
            cx.open_window(options, |window, cx| {
                let view = cx.new(|cx| ControlsSpike::new(window, cx));
                cx.new(|cx| Root::new(view, window, cx))
            })?;
            Ok::<_, anyhow::Error>(())
        })
        .detach();
    });
}
