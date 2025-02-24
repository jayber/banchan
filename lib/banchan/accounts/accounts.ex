defmodule Banchan.Accounts do
  @moduledoc """
  The Accounts context.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Ueberauth.Auth

  alias Banchan.Accounts.{
    ArtistToken,
    DisableHistory,
    InviteRequest,
    Notifications,
    User,
    UserFilter,
    UserToken
  }

  alias Banchan.Repo
  alias Banchan.Uploads
  alias Banchan.Uploads.Upload
  alias Banchan.Workers.{EnableUser, Thumbnailer, UploadDeleter}

  alias BanchanWeb.UserAuth

  @pubsub Banchan.PubSub
  @rand_pass_length 32

  ## Fetching data

  @doc """
  General paginated User-listing query.

  ## Filter

  The second item is a `%UserFilter{}` struct whose values affect the query in the following ways:

    * `:query` - Websearch-style full text search query for finding the user based on its search_vector.

  ## Options

    * `:page_size` - The number of users to return per page.
    * `:page` - The page number to return.

  """
  def list_users(%User{} = actor, %UserFilter{} = filter, opts \\ []) do
    from(u in User,
      as: :user,
      join: a in User,
      as: :actor,
      on: a.id == ^actor.id,
      where: :admin in a.roles or :mod in a.roles,
      where: is_nil(u.deactivated_at),
      order_by: [desc: u.inserted_at]
    )
    |> filter_query(filter)
    |> Repo.paginate(
      page_size: Keyword.get(opts, :page_size, 24),
      page: Keyword.get(opts, :page, 1)
    )
  end

  defp filter_query(q, filter) do
    if filter.query && filter.query != "" do
      q
      |> where(
        [user: u],
        fragment("websearch_to_tsquery(?) @@ (?).search_vector", ^filter.query, u)
      )
    else
      q
    end
  end

  @doc """
  Gets a single user by ID.

  Returns nil if the User does not exist.
  """
  def get_user(nil), do: nil

  def get_user(id) do
    Repo.get(from(u in User, where: is_nil(u.deactivated_at)), id) |> Repo.preload(:disable_info)
  end

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.one(
      from u in User,
        where: u.email == ^email,
        where: is_nil(u.deactivated_at),
        preload: [:pfp_img, :pfp_thumb, :header_img, :disable_info]
    )
  end

  @doc """
  Gets a user by handle. Throws if the user is not found or is deactivated.

  ## Examples

      iex> get_user_by_handle!("foo")
      %User{}

      iex> get_user_by_handle!("unknown")
      Ecto error

  """
  def get_user_by_handle!(handle) when is_binary(handle) do
    Repo.one!(
      from u in User,
        where: u.handle == ^handle and is_nil(u.deactivated_at),
        preload: [:pfp_img, :pfp_thumb, :header_img, :disable_info]
    )
  end

  @doc """
  Gets a user by identifier (email or handle) and password.

  ## Examples

      iex> get_user_by_identifier_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_identifier_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_identifier_and_password(ident, password, opts \\ [])
      when is_binary(ident) and is_binary(password) do
    q =
      from(u in User,
        where: u.email == ^ident or u.handle == ^ident,
        preload: [:pfp_img, :pfp_thumb, :header_img, :disable_info]
      )

    q =
      if Keyword.get(opts, :include_deactivated?) do
        q
      else
        q |> where([u], is_nil(u.deactivated_at))
      end

    user = Repo.one(q)

    if User.valid_password?(user, password), do: user
  end

  @doc """
  Utility for determining whether an actor can modify a target user. Used for
  allowing admins to modify user-only stuff.
  """
  def can_modify_user?(%User{} = actor, %User{} = target) do
    actor.id == target.id ||
      :system in actor.roles ||
      :admin in actor.roles ||
      (:mod in actor.roles && :admin not in target.roles)
  end

  @doc """
  Number of days until full deletion of a deactivated user. It's an error to
  call this on a non-deactivated user.
  """
  def days_until_deletion(%User{deactivated_at: deactivated_at})
      when not is_nil(deactivated_at) do
    case NaiveDateTime.diff(
           NaiveDateTime.add(deactivated_at, 60 * 60 * 24 * 30, :second),
           NaiveDateTime.utc_now()
         ) do
      secs when secs <= 0 ->
        0

      secs ->
        floor(secs / (60 * 60 * 24))
    end
  end

  @doc """
  True if the user is active.
  """
  def active_user?(nil), do: false
  def active_user?(%User{deactivated_at: deactivated_at}), do: is_nil(deactivated_at)

  @doc """
  Finds a user pfp image's Upload.
  """
  def user_pfp_img!(upload_id) do
    from(
      us in User,
      join: u in assoc(us, :pfp_img),
      where: u.id == ^upload_id and is_nil(us.deactivated_at),
      select: u
    )
    |> Repo.one!()
  end

  @doc """
  Finds a user pfp image thumb's Upload.
  """
  def user_pfp_thumb!(upload_id) do
    from(
      us in User,
      join: u in assoc(us, :pfp_thumb),
      where: u.id == ^upload_id and is_nil(us.deactivated_at),
      select: u
    )
    |> Repo.one!()
  end

  @doc """
  Finds a user header image's Upload.
  """
  def user_header_img!(upload_id) do
    from(
      us in User,
      join: u in assoc(us, :header_img),
      where: u.id == ^upload_id and is_nil(us.deactivated_at),
      select: u
    )
    |> Repo.one!()
  end

  @doc """
  Returns true if the user's roles overlap with the given list of roles.
  """
  def has_roles?(%User{roles: user_roles}, roles) do
    Enum.any?(user_roles, &(&1 in roles))
  end

  @doc """
  Returns true if user has mod or admin privs.
  """
  def mod?(%User{} = user) do
    has_roles?(user, [:mod, :admin])
  end

  @doc """
  Returns true if user is an admin.
  """
  def admin?(%User{} = user) do
    has_roles?(user, [:admin])
  end

  @doc """
  Returns true if user is a system user.
  """
  def system?(%User{} = user) do
    has_roles?(user, [:system])
  end

  @doc """
  Fetches the system user.
  """
  def system_user do
    system_user_query()
    |> Repo.one!()
  end

  defp system_user_query do
    from(u in User,
      where: u.handle == "tteokbokki" and :system in u.roles
    )
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The same as above, but used for testing purposes only!

  This is used so that MFA settings and confirmed_at can be set instantly.
  """
  def register_user_test(attrs) do
    %User{}
    |> User.registration_test_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Register an admin.
  """
  def register_admin(attrs) do
    %User{}
    |> User.admin_registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a new special "system" user.
  """
  def register_system(attrs) do
    pw = random_password()

    %User{}
    |> User.system_registration_changeset(
      Enum.into(attrs, %{
        password: pw,
        password_confirmation: pw
      })
    )
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Either find or create a user based on Ueberauth OAuth credentials.
  """
  def handle_oauth(%Auth{provider: :twitter} = auth) do
    Ecto.Multi.new()
    |> Ecto.Multi.one(:user, from(u in User, where: u.twitter_uid == ^auth.uid))
    |> Ecto.Multi.run(:updated_user, fn _, %{user: user} ->
      case user do
        %User{} = user ->
          {:ok, user}

        nil ->
          create_user_from_twitter(auth)
          |> add_oauth_pfp(auth)
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  def handle_oauth(%Auth{provider: :discord} = auth) do
    Ecto.Multi.new()
    |> Ecto.Multi.one(:user, from(u in User, where: u.discord_uid == ^auth.uid))
    |> Ecto.Multi.run(:updated_user, fn _, %{user: user} ->
      case user do
        %User{} = user ->
          {:ok, user}

        nil ->
          create_user_from_discord(auth)
          |> add_oauth_pfp(auth)
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  def handle_oauth(%Auth{provider: :google} = auth) do
    Ecto.Multi.new()
    |> Ecto.Multi.one(:user, from(u in User, where: u.google_uid == ^auth.uid))
    |> Ecto.Multi.run(:updated_user, fn _, %{user: user} ->
      case user do
        %User{} = user ->
          {:ok, user}

        nil ->
          create_user_from_google(auth)
          |> add_oauth_pfp(auth)
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  def handle_oauth(%Auth{}) do
    {:error, :unsupported}
  end

  defp create_user_from_twitter(%Auth{} = auth) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    pw = random_password()

    attrs = %{
      twitter_uid: auth.uid,
      email: auth.info.email,
      handle: auth.info.nickname,
      name: auth.info.name,
      bio: auth.info.description,
      twitter_handle: auth.info.nickname,
      password: pw,
      password_confirmation: pw,
      confirmed_at: now
    }

    case %User{}
         |> User.registration_oauth_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset.errors
        |> Enum.reduce(attrs, fn {field, _}, acc ->
          case field do
            :handle ->
              Map.put(acc, :handle, "user#{:rand.uniform(100_000_000)}")

            :bio ->
              Map.put(
                acc,
                :bio,
                Ecto.Changeset.get_change(changeset, :bio) |> binary_part(0, 160)
              )

            :name ->
              Map.put(
                acc,
                :name,
                Ecto.Changeset.get_change(changeset, :name) |> binary_part(0, 32)
              )

            :email ->
              Map.put(acc, :email, nil)

            _ ->
              acc
          end
        end)
        |> then(&User.registration_oauth_changeset(%User{}, &1))
        |> Repo.insert()
    end
  end

  defp create_user_from_discord(%Auth{} = auth) do
    pw = random_password()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = %{
      discord_uid: auth.uid,
      email: auth.info.email,
      handle:
        auth.extra.raw_info.user["username"] <> "_" <> auth.extra.raw_info.user["discriminator"],
      name:
        auth.extra.raw_info.user["username"] <> "#" <> auth.extra.raw_info.user["discriminator"],
      discord_handle:
        auth.extra.raw_info.user["username"] <> "#" <> auth.extra.raw_info.user["discriminator"],
      password: pw,
      password_confirmation: pw,
      confirmed_at: now
    }

    case %User{}
         |> User.registration_oauth_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset.errors
        |> Enum.reduce(attrs, fn {field, _}, acc ->
          case field do
            :handle ->
              Map.put(acc, :handle, "user#{:rand.uniform(100_000_000)}")

            :name ->
              Map.put(
                acc,
                :name,
                Ecto.Changeset.get_change(changeset, :name) |> binary_part(0, 32)
              )

            :email ->
              Map.put(acc, :email, nil)

            _ ->
              acc
          end
        end)
        |> then(&User.registration_oauth_changeset(%User{}, &1))
        |> Repo.insert()
    end
  end

  defp create_user_from_google(%Auth{} = auth) do
    pw = random_password()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = %{
      google_uid: auth.uid,
      email: auth.info.email,
      handle: "user#{:rand.uniform(100_000_000)}",
      password: pw,
      password_confirmation: pw,
      confirmed_at: now
    }

    case %User{}
         |> User.registration_oauth_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset.errors
        |> Enum.reduce(attrs, fn {field, _}, acc ->
          case field do
            :email ->
              Map.put(acc, :email, nil)

            _ ->
              acc
          end
        end)
        |> then(&User.registration_oauth_changeset(%User{}, &1))
        |> Repo.insert()
    end
  end

  defp add_oauth_pfp({:ok, %User{} = user}, %Auth{info: %{image: url}}) when is_binary(url) do
    tmp_file =
      Path.join([
        System.tmp_dir!(),
        "oauth-pfp-#{:rand.uniform(100_000_000)}" <> Path.extname(url)
      ])

    resp = HTTPoison.get!(url)
    File.write!(tmp_file, resp.body)
    %{format: format} = Mogrify.identify(tmp_file)

    {pfp, thumb} =
      make_pfp_images!(user, user, tmp_file, "image/#{format}", Path.basename(tmp_file))

    File.rm!(tmp_file)

    update_user_profile(user, user, %{
      "pfp_img_id" => pfp.id,
      "pfp_thumb_id" => thumb.id
    })
  end

  defp add_oauth_pfp({:ok, %User{} = user}, %Auth{}) do
    {:ok, user}
  end

  defp add_oauth_pfp({:error, error}, _) do
    {:error, error}
  end

  defp random_password do
    :crypto.strong_rand_bytes(@rand_pass_length) |> Base.encode64()
  end

  ## Admin

  @doc """
  Disables a user.
  """
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def disable_user(%User{} = actor, %User{} = user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:actor, fn _, _ -> {:ok, actor |> Repo.reload()} end)
    |> Ecto.Multi.run(:user, fn _, _ -> {:ok, user |> Repo.reload()} end)
    |> Ecto.Multi.run(:dummy, fn _, _ ->
      {:ok, %DisableHistory{} |> DisableHistory.disable_changeset(attrs)}
    end)
    |> Ecto.Multi.run(:check_valid, fn _, %{actor: actor, user: user, dummy: dummy} ->
      cond do
        !can_modify_user?(actor, user) ->
          {:error, :unauthorized}

        (user |> Repo.preload(:disable_info)).disable_info ->
          {:error, :already_disabled}

        !dummy.valid? ->
          {:error, dummy}

        true ->
          {:ok, true}
      end
    end)
    |> Ecto.Multi.insert(:disable_history, fn %{user: user, actor: actor} ->
      %DisableHistory{
        user_id: user.id,
        disabled_by_id: actor.id,
        disabled_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }
      |> DisableHistory.disable_changeset(attrs)
    end)
    |> Ecto.Multi.run(:unban_job, fn _, %{dummy: dummy, user: user} ->
      case Ecto.Changeset.fetch_change(dummy, :disabled_until) do
        {:ok, until} when not is_nil(until) ->
          EnableUser.schedule_unban(user, until)

        _ ->
          {:ok, nil}
      end
    end)
    |> Ecto.Multi.run(:final_disable_history, fn _,
                                                 %{
                                                   disable_history: disable_history,
                                                   unban_job: job
                                                 } ->
      if job do
        disable_history
        |> DisableHistory.update_job_changeset(job)
        |> Repo.update(returning: true)
      else
        {:ok, disable_history}
      end
    end)
    |> Ecto.Multi.run(:logout, fn _, %{user: user} ->
      logout_user(user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{final_disable_history: disable_history}} ->
        {:ok, disable_history}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  @doc """
  Re-enable a previously disabled user.
  """
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def enable_user(%User{} = actor, %User{} = user, reason, cancel \\ true) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:actor, fn _, _ -> {:ok, actor |> Repo.reload()} end)
    |> Ecto.Multi.run(:user, fn _, _ -> {:ok, user |> Repo.reload()} end)
    |> Ecto.Multi.run(:check_valid, fn _, %{actor: actor, user: user} ->
      if can_modify_user?(actor, user) do
        {:ok, true}
      else
        {:error, :unauthorized}
      end
    end)
    |> Ecto.Multi.run(:disable_changeset, fn _, _ ->
      changeset = DisableHistory.enable_changeset(%DisableHistory{}, %{lifted_reason: reason})

      if changeset.valid? do
        {:ok, changeset}
      else
        {:error, changeset}
      end
    end)
    |> Ecto.Multi.update_all(
      :update_histories,
      fn %{actor: actor, user: user} ->
        # We're a little heavy-handed here in case of the very unlikely
        # scenario where we get multiple concurrent bans in place.
        # Better to just clean those up while we're at it.
        actor_id = actor && actor.id
        lifted_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        from(h in DisableHistory,
          where: h.user_id == ^user.id and is_nil(h.lifted_at),
          select: h,
          update: [
            set: [
              lifted_at: ^lifted_at,
              lifted_by_id: ^actor_id,
              lifted_reason: ^reason
            ]
          ]
        )
      end,
      []
    )
    |> Ecto.Multi.run(:cancel_unban, fn _, %{update_histories: {_, [history | _]}} ->
      if cancel do
        EnableUser.cancel_unban(history)
      end

      {:ok, nil}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{update_histories: {_, [history | _]}}} ->
        {:ok, history}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  ## Settings and Profile

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user handle.

  ## Examples

      iex> change_user_handle(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_handle(user, attrs \\ %{}) do
    User.handle_changeset(user, attrs)
  end

  @doc """
  Updates admin-level fields for a user, such as their roles.
  """
  def update_admin_fields(%User{} = actor, %User{} = user, attrs \\ %{}) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:actor, fn _, _ ->
      actor = actor |> Repo.reload()

      if mod?(actor) do
        {:ok, actor}
      else
        {:error, :unauthorized}
      end
    end)
    |> Ecto.Multi.run(:user, fn _, _ -> {:ok, user |> Repo.reload()} end)
    |> Ecto.Multi.update(
      :updated_user,
      fn %{actor: actor, user: user} ->
        User.admin_changeset(actor, user, attrs)
      end,
      returning: true
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  @doc """
  Updates the user profile fields.

  ## Examples

      iex> update_user_profile(actor, user, %{handle: ..., bio: ..., ...})
      {:ok, %User{}}

  """
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def update_user_profile(%User{} = actor, %User{} = user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:user, fn _, _ -> {:ok, user |> Repo.reload()} end)
    |> Ecto.Multi.run(:actor, fn _, _ ->
      actor = actor |> Repo.reload()

      if can_modify_user?(actor, user) do
        {:ok, actor}
      else
        {:error, :unauthorized}
      end
    end)
    |> Ecto.Multi.update(
      :updated_user,
      fn _ ->
        # NB(@zkat): We use the passed-in user, not the re-read user here.
        user
        |> User.profile_changeset(attrs)
      end,
      returning: true
    )
    |> Ecto.Multi.run(:remove_old_pfp_img, fn _, %{updated_user: updated, user: old} ->
      if old.pfp_img_id && old.pfp_img_id != updated.pfp_img_id do
        UploadDeleter.schedule_deletion(%Upload{id: old.pfp_img_id})
      else
        {:ok, nil}
      end
    end)
    |> Ecto.Multi.run(:remove_old_pfp_thumb, fn _, %{updated_user: updated, user: old} ->
      if old.pfp_thumb_id && old.pfp_thumb_id != updated.pfp_thumb_id do
        UploadDeleter.schedule_deletion(%Upload{id: old.pfp_thumb_id})
      else
        {:ok, nil}
      end
    end)
    |> Ecto.Multi.run(:remove_old_header_img, fn _, %{updated_user: updated, user: old} ->
      if old.header_img_id && old.header_img_id != updated.header_img_id do
        UploadDeleter.schedule_deletion(%Upload{id: old.header_img_id})
      else
        {:ok, nil}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  @doc """
  Saves a profile picture and schedules generation of corresponding thumbnails.
  """
  def make_pfp_images!(%User{} = actor, %User{} = user, src, type, name) do
    if can_modify_user?(actor, user) do
      upload = Uploads.save_file!(user, src, type, name)

      {:ok, pfp} =
        Thumbnailer.thumbnail(
          upload,
          dimensions: "512x512",
          name: "profile.jpg"
        )

      {:ok, thumb} =
        Thumbnailer.thumbnail(
          upload,
          dimensions: "128x128",
          name: "thumbnail.jpg"
        )

      {pfp, thumb}
    else
      raise "Unauthorized"
    end
  end

  @doc """
  Saves a header image and schedules generation of processed version for site display.
  """
  def make_header_image!(%User{} = actor, %User{} = user, src, type, name) do
    if can_modify_user?(actor, user) do
      upload = Uploads.save_file!(user, src, type, name)

      {:ok, header} =
        Thumbnailer.thumbnail(
          upload,
          dimensions: "1200",
          name: "header.jpg"
        )

      header
    else
      raise "Unauthorized"
    end
  end

  @doc """
  Updates the user handle.

  ## Examples

      iex> update_user_handle(user, "valid password", %{handle: ...})
      {:ok, %User{}}

      iex> update_user_handle(user, "invalid password", %{handle: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_handle(user, password, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :user,
      fn _ ->
        changeset = user |> User.handle_changeset(attrs)

        if user.email do
          changeset |> User.validate_current_password(password)
        else
          changeset
        end
      end,
      returning: true
    )
    |> Ecto.Multi.delete_all(:logout_user, fn %{user: user} ->
      UserToken.user_and_contexts_query(user, :all)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  @doc """
  Emulates that the email will change without actually changing it in the
  database. Used exclusively for OAuth accounts that didn't have an email to
  begin with, so password is not checked.

  ## Examples

      iex> apply_new_user_email(user, %{email: ...})
      {:ok, %User{}}
  """
  def apply_new_user_email(user, attrs) do
    user = user |> Repo.reload()

    if is_nil(user.email) do
      user
      |> User.email_changeset(attrs)
      |> Ecto.Changeset.apply_action(:update)
    else
      {:error, :has_email}
    end
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_email(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, email, context)) do
      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, email, context) do
    changeset = user |> User.email_changeset(%{email: email}) |> User.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, [context]))
  end

  @doc """
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_update_email_instructions(user, current_email, &Routes.user_update_email_url(conn, :edit, &1))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    Notifications.update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Generates a new TOTP secret for a user.

  ## Examples

      iex> generate_totp_secret(user)
      {:ok, %User{}}

      iex> generate_totp_secret(user)
      {:error, %Ecto.Changeset{}}

  """
  def generate_totp_secret(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:user, fn _, _ ->
      user = user |> Repo.reload()

      if user.totp_activated do
        {:error, :totp_activated}
      else
        {:ok, user}
      end
    end)
    |> Ecto.Multi.update(
      :updated_user,
      fn %{user: user} ->
        secret = NimbleTOTP.secret()

        user
        |> User.totp_secret_changeset(%{totp_secret: secret, totp_activated: false})
      end,
      returning: true
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  @doc """
  Deactivates a user's TOTP secret.

  ## Examples

      iex> deactivate_totp(user, password)
      {:ok, %User{}}

      iex> deactivate_totp(user, badpassword)
      {:error, :invalid_password}

  """
  def deactivate_totp(user, password) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:user, fn _, _ ->
      user = user |> Repo.reload()

      if User.valid_password?(user, password) do
        {:ok, user}
      else
        {:error, :invalid_password}
      end
    end)
    |> Ecto.Multi.update(
      :updated_user,
      fn %{user: user} ->
        user
        |> User.totp_secret_changeset(%{totp_secret: nil, totp_activated: false})
      end,
      returning: true
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  @doc """
  Activates a TOTP secret for a user.

  ## Examples

      iex> activate_totp(user, token)
      {:ok, %User{}}

      iex> activate_totp(user, badtoken)
      {:error, :invalid_token}

  """
  def activate_totp(user, token) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:user, fn _, _ ->
      user = user |> Repo.reload()

      if NimbleTOTP.valid?(user.totp_secret, token) do
        {:ok, user}
      else
        {:error, :invalid_token}
      end
    end)
    |> Ecto.Multi.update(:updated_user, fn %{user: user} ->
      user
      |> User.totp_secret_changeset(%{totp_activated: true})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, error, _} ->
        {:error, error}
    end
  end

  @doc """
  Updates the user's preferences for mature content filtering.
  """
  def update_maturity(user, attrs) do
    user
    |> User.maturity_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the user's preferences for muted words.
  """
  def update_muted(user, attrs) do
    user
    |> User.muted_changeset(attrs)
    |> Repo.update()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query) |> Repo.preload(:disable_info)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_session_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Logs out a user from everything.
  """
  def logout_user(%User{} = user) do
    # Delete all user tokens
    {n, _} = Repo.delete_all(UserToken.user_and_contexts_query(user, :all))

    if n > 0 do
      # Broadcast to all LiveViews to immediately disconnect the user
      Phoenix.PubSub.broadcast_from(
        @pubsub,
        self(),
        UserAuth.pubsub_topic(),
        %Phoenix.Socket.Broadcast{
          topic: UserAuth.pubsub_topic(),
          event: "logout_user",
          payload: %{
            user: user
          }
        }
      )
    end

    {:ok, user}
  end

  @doc """
  Subscribes the current process to auth-related events (such as `logout_user`).
  """
  def subscribe_to_auth_events do
    Phoenix.PubSub.subscribe(@pubsub, UserAuth.pubsub_topic())
  end

  ## Confirmation

  @doc """
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &Routes.user_confirmation_url(conn, :confirm, &1))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_confirmation_instructions(confirmed_user, &Routes.user_confirmation_url(conn, :confirm, &1))
      {:error, :already_confirmed}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      Notifications.confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["confirm"]))
  end

  ## Reset password

  @doc """
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &Routes.user_reset_password_url(conn, :edit, &1))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    Notifications.reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user |> Repo.preload(:disable_info)
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, %User{}}

      iex> reset_user_password(user, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  """
  def reset_user_password(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Artist Invites

  @doc """
  Lists invite requests.

  ## Options

    * `:unsent_only` - Only list invites that havent' had tokens generated for them.
    * `:email_filter` - Prefix filter to apply to search for emails.
    * `:page` - The page of results to return.
    * `:page_size` - How many results to return per page.
  """
  def list_invite_requests(opts \\ []) do
    q =
      from(
        r in InviteRequest,
        as: :request,
        order_by: [asc: r.inserted_at],
        preload: [token: [:used_by, :generated_by]]
      )

    q =
      case Keyword.fetch(opts, :unsent_only) do
        {:ok, true} ->
          q |> where([request: r], is_nil(r.token_id))

        _ ->
          q
      end

    q =
      case Keyword.fetch(opts, :email_filter) do
        {:ok, filter} when is_binary(filter) ->
          filter = filter <> "%"
          q |> where([request: r], ilike(r.email, ^filter))

        _ ->
          q
      end

    q
    |> Repo.paginate(
      page_size: Keyword.get(opts, :page_size, 24),
      page: Keyword.get(opts, :page, 1)
    )
  end

  @doc """
  Adds artist invites to a user so they can send them out.
  """
  def add_artist_invites(%User{} = user, n) when is_integer(n) do
    {1, [%User{} = user]} =
      from(u in User,
        where: u.id == ^user.id,
        select: u,
        update: [
          set: [available_invites: coalesce(u.available_invites, 0) + ^n]
        ]
      )
      |> Repo.update_all([])

    {:ok, user}
  end

  @doc """
  Sends a batch of invites to the `n` oldest emails.
  """
  def send_invite_batch(%User{} = actor, n, invite_url_fun) when is_integer(n) do
    Ecto.Multi.new()
    |> Ecto.Multi.all(
      :requests,
      from(r in InviteRequest,
        order_by: [asc: r.inserted_at],
        limit: ^n,
        where: is_nil(r.token_id),
        lock: "FOR UPDATE"
      )
    )
    |> Ecto.Multi.run(:sent_invites, fn _repo, %{requests: requests} ->
      requests
      |> Enum.reduce_while({:ok, []}, fn request, {:ok, requests} ->
        case send_invite(actor, request, invite_url_fun) do
          {:ok, request} ->
            {:cont, {:ok, [request | requests]}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{sent_invites: requests}} ->
        {:ok, requests |> Enum.reverse()}

      {:error, _, :no_invites, _} ->
        {:error, :no_invites}

      {:error, _, error, _} ->
        Logger.error("Unexpected error sending artist invite: %{inspect(err)}")
        {:error, error}
    end
  end

  @doc """
  Generates a token and sends an invite email for a given `InviteRequest`.
  """
  def send_invite(%User{} = actor, email, invite_url_fun) when is_binary(email) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:request, fn _repo, _changes ->
      add_invite_request(email)
    end)
    |> Ecto.Multi.run(:updated_request, fn _repo, %{request: request} ->
      send_invite(actor, request, invite_url_fun)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_request: request}} -> {:ok, request}
      {:error, _, error, _} -> {:error, error}
    end
  end

  def send_invite(%User{} = actor, %InviteRequest{} = request, invite_url_fun) do
    Ecto.Multi.new()
    |> Ecto.Multi.one(:actor, from(u in User, where: u.id == ^actor.id))
    |> Ecto.Multi.one(
      :request,
      from(r in InviteRequest, where: r.id == ^request.id, lock: "FOR UPDATE")
    )
    |> Ecto.Multi.run(:check_args, fn _repo, %{actor: actor, request: request} ->
      cond do
        is_nil(request) ->
          {:error, :request_not_found}

        is_nil(actor) ->
          {:error, :actor_not_found}

        true ->
          {:ok, true}
      end
    end)
    |> Ecto.Multi.run(:token, fn _repo, %{actor: actor} ->
      generate_artist_token(actor)
    end)
    |> Ecto.Multi.update(:updated_request, fn %{request: request, token: token} ->
      request |> InviteRequest.update_token_changeset(token)
    end)
    |> Ecto.Multi.run(:email_job, fn _repo, %{updated_request: request, token: token} ->
      Notifications.artist_invite(request.email, invite_url_fun.(token.token))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_request: request}} ->
        {:ok, request}

      {:error, _, err, _} ->
        {:error, err}
    end
  end

  @doc """
  Adds an email to the artist signup queue.
  """
  def add_invite_request(email, requested_at \\ nil) do
    %InviteRequest{
      inserted_at: requested_at
    }
    |> InviteRequest.changeset(%{
      email: email
    })
    |> Repo.insert()
  end

  @doc """
  Imports invites from a CSV file.
  """
  def import_invites_from_csv!(file) do
    File.stream!(file)
    |> CSV.decode!(headers: true)
    |> Enum.each(fn %{"email" => email, "created_at" => created_at} ->
      {:ok, _} =
        add_invite_request(
          email,
          Timex.parse!(created_at, "{ISO:Extended:Z}")
          |> DateTime.to_naive()
          |> NaiveDateTime.truncate(:second)
        )
    end)

    :ok
  end

  @doc """
  Gets an invite request by its id.
  """
  def get_invite_request(id) do
    Repo.get(InviteRequest, id)
  end

  @doc """
  Delivers a confirmation email letting someone know that they've been signed up for the beta.
  """
  def deliver_artist_invite_confirmation(%InviteRequest{} = request) do
    Notifications.invite_request_confirmation(request.email)
  end

  @doc """
  Generates an artist invite token.
  """
  def generate_artist_token(%User{} = actor) do
    Ecto.Multi.new()
    |> Ecto.Multi.one(:user, from(u in User, where: u.id == ^actor.id, lock: "FOR UPDATE"))
    |> Ecto.Multi.run(:new_invite_count, fn _repo, %{user: %User{} = user} ->
      case user.available_invites do
        n when n > 0 ->
          {:ok, n - 1}

        _ ->
          if mod?(user) || system?(user) do
            {:ok, 0}
          else
            {:error, :no_invites}
          end
      end
    end)
    |> Ecto.Multi.update(:updated_user, fn %{user: %User{} = user, new_invite_count: n} ->
      user
      |> User.update_invite_count_changeset(n)
    end)
    |> Ecto.Multi.insert(:artist_token, fn %{user: %User{} = user} ->
      %ArtistToken{
        generated_by_id: user.id,
        token: ArtistToken.build_token()
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{artist_token: artist_token}} ->
        {:ok, artist_token}

      {:error, _, err, _} ->
        {:error, err}
    end
  end

  @doc """
  Fetches an ArtistToken by its base64 token string.
  """
  def get_artist_token(token) do
    from(t in ArtistToken, where: t.token == ^token)
    |> Repo.one()
  end

  @doc """
  Applies an invite token to a user, adding the :artist role.
  """
  def apply_artist_token(%User{} = user, token) do
    Ecto.Multi.new()
    |> Ecto.Multi.one(:user, from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"))
    |> Ecto.Multi.run(:new_roles, fn _repo, %{user: %User{} = user} ->
      if :artist in user.roles do
        {:error, :already_artist}
      else
        new_roles =
          if is_nil(user.roles) do
            []
          else
            [:artist | user.roles]
          end

        {:ok, new_roles}
      end
    end)
    |> Ecto.Multi.one(:system, system_user_query())
    |> Ecto.Multi.one(
      :token,
      from(t in ArtistToken, where: t.token == ^token, lock: "FOR UPDATE")
    )
    |> Ecto.Multi.run(:check_token_unused, fn _repo, %{token: token} ->
      cond do
        is_nil(token) ->
          {:error, :invalid_token}

        !is_nil(token.used_by_id) ->
          {:error, :token_used}

        true ->
          {:ok, token}
      end
    end)
    |> Ecto.Multi.update(:update_roles, fn %{
                                             new_roles: new_roles,
                                             user: %User{} = user,
                                             system: %User{} = system
                                           } ->
      User.roles_changeset(system, user, %{roles: new_roles})
    end)
    |> Ecto.Multi.update(:updated_token, fn %{token: token, user: %User{} = user} ->
      token |> ArtistToken.used_by_changeset(%{used_by_id: user.id})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_token: %ArtistToken{} = token}} ->
        {:ok, token}

      {:error, _, value, _} ->
        {:error, value}
    end
  end

  ## Deletion/Deactivation

  @doc """
  Reactivates a previously-deactivated user, preventing them from getting deleted.
  """
  def reactivate_user(%User{} = actor, %User{} = user) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:user, fn _, _ ->
      actor = actor |> Repo.reload()

      if actor.id == user.id || admin?(actor) do
        {:ok, user}
      else
        {:error, :unauthorized}
      end
    end)
    |> Ecto.Multi.update(
      :updated_user,
      fn %{user: user} ->
        user |> User.reactivate_changeset()
      end,
      returning: true
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, err, _} ->
        {:error, err}
    end
  end

  @doc """
  Deactivates a user, scheduling them for deletion, but retaining user data.
  """
  def deactivate_user(%User{} = actor, %User{} = user, password) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:actor, fn _, _ -> {:ok, actor |> Repo.reload()} end)
    |> Ecto.Multi.run(:user, fn _, _ -> {:ok, user |> Repo.reload()} end)
    |> Ecto.Multi.run(:check_allowed, fn _, %{actor: actor, user: user} ->
      if actor.id == user.id || (admin?(actor) && !admin?(user)) do
        {:ok, user}
      else
        {:error, :unauthorized}
      end
    end)
    |> Ecto.Multi.update(
      :updated_user,
      fn %{user: user, actor: actor} ->
        user
        |> User.deactivate_changeset()
        |> then(fn changeset ->
          # NB(@zkat): Users without emails are OAuth users. They also
          # do not have passwords. So we just skip the password check.
          if user.email && !admin?(actor) do
            User.validate_current_password(changeset, password)
          else
            changeset
          end
        end)
      end,
      returning: true
    )
    |> Ecto.Multi.run(:logout, fn _, %{updated_user: user} ->
      logout_user(user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{updated_user: user}} ->
        {:ok, user}

      {:error, _, value, _} ->
        {:error, value}
    end
  end

  @doc """
  Prunes all users that were deactivated more than 30 days ago.

  Database constraints will take care of nilifying foreign keys or cascading
  deletions.
  """
  def prune_users do
    now = NaiveDateTime.utc_now()

    Repo.transaction(fn ->
      from(
        u in User,
        where: not is_nil(u.deactivated_at),
        where: u.deactivated_at < datetime_add(^now, -30, "day")
      )
      |> Repo.stream()
      |> Enum.reduce(0, fn user, acc ->
        # NB(@zkat): We hard match on `{:ok, _}` here because scheduling
        # deletions should really never fail.
        if user.pfp_img_id do
          {:ok, _} = UploadDeleter.schedule_deletion(%Upload{id: user.pfp_img_id})
        end

        if user.pfp_thumb_id do
          {:ok, _} = UploadDeleter.schedule_deletion(%Upload{id: user.pfp_thumb_id})
        end

        if user.header_img_id do
          {:ok, _} = UploadDeleter.schedule_deletion(%Upload{id: user.header_img_id})
        end

        case Repo.delete(user) do
          {:ok, _} ->
            acc + 1

          {:error, error} ->
            Logger.error("Failed to prune user #{user.handle}: #{inspect(error)}")
            acc
        end
      end)
    end)
  end
end
