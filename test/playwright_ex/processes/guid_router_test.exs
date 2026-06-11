defmodule PlaywrightEx.GuidRouterTest do
  use ExUnit.Case, async: false

  alias PlaywrightEx.GuidRouter

  @timeout Application.compile_env(:playwright_ex, :timeout)

  describe "route/2" do
    test "falls back to the default for unknown guids" do
      assert GuidRouter.route("frame@unknown", Default) == Default
    end

    test "well-known singleton guids are never registered" do
      GuidRouter.put("Playwright", Other)
      GuidRouter.put("localUtils", Other)

      assert GuidRouter.route("Playwright", Default) == Default
      assert GuidRouter.route("localUtils", Default) == Default
    end

    test "registered guids resolve to their owning connection" do
      GuidRouter.put("frame@router-test", Other)
      on_exit(fn -> GuidRouter.delete("frame@router-test") end)

      assert GuidRouter.route("frame@router-test", Default) == Other

      GuidRouter.delete("frame@router-test")
      assert GuidRouter.route("frame@router-test", Default) == Default
    end
  end

  describe "multiple connections" do
    @tag timeout: 60_000
    test "channel calls route to the owning connection without an explicit :connection" do
      name = MultiConnectionTest

      start_supervised!(
        {PlaywrightEx.Supervisor, :playwright_ex |> Application.get_all_env() |> Keyword.put(:name, name)},
        restart: :temporary
      )

      connection = PlaywrightEx.Supervisor.connection_name(name)

      # Launch on the second connection explicitly ...
      {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout, connection: connection)
      on_exit(fn -> PlaywrightEx.Browser.close(browser.guid, timeout: @timeout) end)

      # ... then operate on its objects WITHOUT passing :connection.
      {:ok, browser_context} = PlaywrightEx.Browser.new_context(browser.guid, timeout: @timeout)
      {:ok, page} = PlaywrightEx.BrowserContext.new_page(browser_context.guid, timeout: @timeout)
      frame_id = page.main_frame.guid

      assert {:ok, _} = PlaywrightEx.Frame.goto(frame_id, url: "about:blank", timeout: @timeout)

      assert {:ok, "routed"} =
               PlaywrightEx.Frame.evaluate(frame_id,
                 expression: "() => 'routed'",
                 is_function: true,
                 timeout: @timeout
               )

      # Event-based waits (FrameEventRecorder) must also route by guid.
      assert {:ok, _} = PlaywrightEx.Frame.wait_for_url(frame_id, url: "about:blank", timeout: @timeout)
    end
  end
end
