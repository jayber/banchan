defmodule BanchanWeb.CommissionLive.Components.StatusBox do
  @moduledoc """
  Shows the current status of the commission.
  """
  use BanchanWeb, :component

  alias Banchan.Commissions

  prop current_user, :struct, from_context: :current_user
  prop current_user_member?, :boolean, from_context: :current_user_member?
  prop commission, :struct, from_context: :commission

  def render(assigns) do
    ~F"""
    <div class="w-full">
      <div class="flex flex-row gap-2 items-center">
        <div class="text-xl font-medium">
          Status:
        </div>
        <div class="badge badge-primary badge-lg flex flex-row gap-2 items-center cursor-default">
          {Commissions.Common.humanize_status(@commission.status)}
          {#if @current_user.id == @commission.client_id}
            <div class="tooltip md:tooltip-left" data-tip={tooltip_message(@commission.status, false)}>
              <i class="fas fa-info-circle" />
            </div>
          {/if}
          {#if @current_user_member?}
            <div class="tooltip md:tooltip-left" data-tip={tooltip_message(@commission.status, true)}>
              <i class="fas fa-info-circle" />
            </div>
          {/if}
        </div>
      </div>
    </div>
    """
  end

  defp tooltip_message(status, current_user_member?)

  defp tooltip_message(:submitted, false) do
    "You have submitted this commission. Please wait while the studio decides whether to accept it."
  end

  defp tooltip_message(:accepted, false) do
    "The studio has accepted this commission and has committed to working on it."
  end

  defp tooltip_message(:rejected, false) do
    "The studio has rejected this commission. You may submit a separate one if appropriate."
  end

  defp tooltip_message(:in_progress, false) do
    "The studio has begun work on this commission. Keep an eye out for drafts!"
  end

  defp tooltip_message(:paused, false) do
    "The studio has temporarily paused work on this commission."
  end

  defp tooltip_message(:waiting, false) do
    "The studio is waiting for your response before continuing work."
  end

  defp tooltip_message(:ready_for_review, false) do
    "This commission is ready for your final review. If you approve it, you agree to release all payments to the studio for payout."
  end

  defp tooltip_message(:approved, false) do
    "This commission has been approved. All deposits will be released to the studio."
  end

  defp tooltip_message(:withdrawn, false) do
    "This commission has been withdrawn. You may request a refund of deposited but unreleased funds from the studio, separately."
  end

  defp tooltip_message(:submitted, true) do
    "This commission has been submitted for acceptance. Accepting it will mark slots as used if you've configured them for this commission. By accepting this commission, this studio commits to working on it soon."
  end

  defp tooltip_message(:accepted, true) do
    "This studio has accepted this commission but has not begun work on it yet."
  end

  defp tooltip_message(:rejected, true) do
    "This studio has rejected this commission and will not be working on it."
  end

  defp tooltip_message(:in_progress, true) do
    "This commission is actively being worked on."
  end

  defp tooltip_message(:paused, true) do
    "Ths studio has temporarily paused work on this commission."
  end

  defp tooltip_message(:waiting, true) do
    "The studio is waiting for a client response before continuing work."
  end

  defp tooltip_message(:ready_for_review, true) do
    "This commission has been marked for final review. The client will determine whether to close it out and pay out any money deposited so far."
  end

  defp tooltip_message(:withdrawn, true) do
    "This commission has been withdrawn. It is recommended that you refund any deposits to the client."
  end

  defp tooltip_message(:approved, true) do
    "This commission has been approved by the client. Any deposits will be released to you for payout once available."
  end
end
