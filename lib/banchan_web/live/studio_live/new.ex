defmodule BanchanWeb.StudioLive.New do
  @moduledoc """
  New studio creation page.
  """
  use BanchanWeb, :surface_view

  import Slug
  alias Surface.Components.Form

  alias Banchan.Studios
  alias Banchan.Studios.Studio

  alias BanchanWeb.Components.Form.{
    Checkbox,
    MarkdownInput,
    MultipleSelect,
    Select,
    Submit,
    TextInput
  }

  alias BanchanWeb.Components.Layout
  alias BanchanWeb.Endpoint

  @impl true
  def mount(_params, _session, socket) do
    currencies =
      Studios.Common.supported_currencies()
      |> Enum.map(fn currency ->
        %{name: name, symbol: symbol} = Money.Currency.get(currency)
        {:"#{name} (#{symbol})", currency}
      end)

    socket =
      socket
      |> assign(
        countries: Studios.Common.supported_countries(),
        currencies: currencies
      )

    if is_nil(socket.assigns.current_user.confirmed_at) do
      socket =
        put_flash(
          socket,
          :warning,
          "You must verify your email address before creating your own studio."
        )

      {:ok,
       push_redirect(socket,
         to: Routes.confirmation_path(Endpoint, :show)
       )}
    else
      changeset = Studio.creation_changeset(%Studio{}, %{})
      {:ok, assign(socket, changeset: changeset)}
    end
  end

  @impl true
  def handle_event("change", %{"studio" => studio, "_target" => target}, socket) do
    studio =
      if target == ["studio", "name"] do
        %{studio | "handle" => slugify(studio["name"])}
      else
        studio
      end

    changeset =
      %Studio{}
      |> Studio.profile_changeset(studio)
      |> Map.put(:action, :update)

    socket = assign(socket, changeset: changeset)
    {:noreply, socket}
  end

  @impl true
  def handle_event("submit", val, socket) do
    case Studios.new_studio(
           %Studio{artists: [socket.assigns.current_user]},
           val["studio"]
         ) do
      {:ok, studio} ->
        {:noreply,
         socket
         |> put_flash(:info, "Studio created")
         |> redirect(to: Routes.studio_shop_path(Endpoint, :show, studio.handle))}

      other ->
        other
    end
  end

  @impl true
  def render(assigns) do
    ~F"""
    <Layout flashes={@flash} padding={0}>
      <div class="w-full md:bg-base-300">
        <div class="max-w-sm w-full rounded-xl p-10 mx-auto md:my-10 bg-base-100">
          <Form
            class="col-span-1"
            for={@changeset}
            change="change"
            submit="submit"
            opts={autocomplete: "off"}
          >
            <h1 class="text-2xl">New Studio</h1>
            <TextInput
              name={:name}
              icon="user"
              info="The studio's display name, as it should appear on studio cards and its home page."
              opts={required: true, phx_debounce: "200"}
            />
            <TextInput
              name={:handle}
              icon="at"
              info="Unique studio handle, as it will appear in the URL."
              opts={required: true}
            />
            <MarkdownInput
              id="about"
              info="Tell us about your studio, what kind of art it's for, and what makes it different!"
              name={:about}
            />
            <Checkbox
              name={:mature}
              label="Mature"
              info="Mark this studio as exclusively for mature content. You can still make indiviual mature offerings if this is unchecked."
            />
            <Select
              name={:country}
              info="Country where you are based. This must be the same country where your bank is, and it's the only reason we collect this information."
              options={@countries}
              selected={:US}
              opts={required: true}
            />
            <Select
              name={:default_currency}
              info="Currency that will appear by default in your currency drop down (if you choose more than one currency)."
              prompt="Pick a currency..."
              selected={:USD}
              options={@currencies}
              opts={required: true}
            />
            <MultipleSelect
              name={:payment_currencies}
              info="Currencies you want to invoice with. Note that people from other countries can still pay you even if their local currency isn't listed here, so you can just pick based on what will look right for your clients."
              options={@currencies}
              selected={:USD}
              opts={required: true}
            />
            <Submit changeset={@changeset} label="Save" />
          </Form>
        </div>
      </div>
    </Layout>
    """
  end
end
