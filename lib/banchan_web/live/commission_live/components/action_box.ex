defmodule BanchanWeb.CommissionLive.Components.ActionBox do
  @moduledoc """
  Action box for showing clients and artists the various actions they can take next.
  """
  use BanchanWeb, :live_component

  alias Banchan.Accounts
  alias Banchan.Commissions
  alias Banchan.Payments

  alias BanchanWeb.Components.{Button, Collapse}

  prop current_user, :struct, from_context: :current_user
  prop current_user_member?, :boolean, from_context: :current_user_member?
  prop commission, :struct, from_context: :commission

  data invoices_paid?, :boolean

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    invoices = Payments.list_invoices(commission: socket.assigns.commission)

    invoices_paid? =
      !Enum.empty?(invoices) &&
        Enum.all?(invoices, &Payments.invoice_finished?(&1)) &&
        Enum.any?(invoices, &Payments.invoice_paid?(&1))

    {:ok, socket |> assign(invoices_paid?: invoices_paid?)}
  end

  def handle_event("update_status", %{"value" => status}, socket) do
    case Commissions.update_status(socket.assigns.current_user, socket.assigns.commission, status) do
      {:ok, _} ->
        Collapse.set_open(socket.assigns.id <> "-approval-collapse", false)
        Collapse.set_open(socket.assigns.id <> "-review-confirm-collapse", false)
        {:noreply, socket}

      {:error, :blocked} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are blocked from further interaction with this studio.")
         |> push_redirect(
           to: Routes.commission_path(Endpoint, :show, socket.assigns.commission.public_id)
         )}
    end
  end

  def render(assigns) do
    ~F"""
    <div class="rounded-lg border-2 p-2">
      {#if @current_user.id == @commission.client_id || Accounts.mod?(@current_user)}
        <div class="flex flex-col gap-2">
          {#case @commission.status}
            {#match :ready_for_review}
              {approve(assigns)}
            {#match :withdrawn}
              <Button class="w-full" click="update_status" value="submitted" label="Submit Again" />
            {#match _}
          {/case}
        </div>
      {/if}
      {#if @current_user_member? || Accounts.mod?(@current_user)}
        <div class="flex flex-col gap-2">
          {#case @commission.status}
            {#match :submitted}
              <Button class="w-full" click="update_status" value="accepted" label="Accept" />
            {#match :accepted}
              <Button
                class="w-full"
                click="update_status"
                value="in_progress"
                label="Mark as In Progress"
              />
              <Button class="w-full" click="update_status" value="paused" label="Pause Work" />
              {ready_for_review(assigns)}
            {#match :rejected}
              <Button class="w-full" click="update_status" value="accepted" label="Reopen" />
            {#match :in_progress}
              <Button class="w-full" click="update_status" value="paused" label="Pause Work" />
              <Button class="w-full" click="update_status" value="waiting" label="Wait for Client" />
              {ready_for_review(assigns)}
            {#match :paused}
              <Button class="w-full" click="update_status" value="waiting" label="Wait for Client" />
              <Button class="w-full" click="update_status" value="in_progress" label="Resume" />
            {#match :waiting}
              <Button class="w-full" click="update_status" value="in_progress" label="Resume" />
              <Button class="w-full" click="update_status" value="paused" label="Pause Work" />
              {ready_for_review(assigns)}
            {#match :ready_for_review}
              <Button
                class="w-full"
                click="update_status"
                value="in_progress"
                label="Return to In Progress"
              />
            {#match :withdrawn}
              <Button class="w-full" click="update_status" value="accepted" label="Reopen" />
            {#match :approved}
              <Button class="w-full" click="update_status" value="accepted" label="Reopen" />
          {/case}
        </div>
      {/if}
    </div>
    """
  end

  defp approve(assigns) do
    ~F"""
    <Collapse id={@id <> "-approval-collapse"} show_arrow={false}>
      <:header>
        <Button class="w-full" label="Approve" />
      </:header>
      <p>
        All deposited funds will be made available immediately to the studio and the commission will be closed.
      </p>
      <p class="font-bold text-warning">WARNING: This is final and you will not be able to request a refund once approved.</p>
      <Button
        class="w-full"
        click="update_status"
        value="approved"
        label="Confirm"
        opts={phx_target: @myself}
      />
    </Collapse>
    """
  end

  defp ready_for_review(assigns) do
    ~F"""
    {#if @invoices_paid?}
      <Button
        class="w-full"
        click="update_status"
        value="ready_for_review"
        label="Request Final Approval"
        opts={phx_target: @myself}
      />
    {#else}
      <Collapse id={@id <> "-review-confirm-collapse"} show_arrow={false}>
        <:header>
          <Button class="w-full" label="Request Final Approval" />
        </:header>
        <p>You're requesting final approval for a commission before any/all invoices have been completed.</p>
        <p>It's recommended you invoice your client before they are able to approve a commission.</p>
        <p>Are you sure you want to proceed?</p>
        <Button
          class="w-full"
          click="update_status"
          value="ready_for_review"
          label="Confirm"
          opts={phx_target: @myself}
        />
      </Collapse>
    {/if}
    """
  end
end
