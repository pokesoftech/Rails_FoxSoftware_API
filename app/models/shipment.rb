# == Schema Information
#
# Table name: shipments
#
#  id                   :integer          not null, primary key
#  notes                :string
#  picture              :string
#  secret_id            :string
#  weight               :decimal(10, 2)   default(0.0)
#  dim_w                :decimal(10, 2)   default(0.0)
#  dim_h                :decimal(10, 2)   default(0.0)
#  dim_l                :decimal(10, 2)   default(0.0)
#  distance             :integer          not null
#  n_of_cartons         :integer          default(0)
#  cubic_feet           :integer          default(0)
#  unit_count           :integer          default(0)
#  skids_count          :integer          default(0)
#  user_id              :integer
#  original_shipment_id :integer
#  hazard               :boolean          default(FALSE)
#  private_bidding      :boolean          default(FALSE)
#  active               :boolean          default(TRUE)
#  stackable            :boolean          default(TRUE)
#  price                :decimal(10, 2)
#  pickup_at            :datetime         not null
#  arrive_at            :datetime         not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  shipper_info_id      :integer
#  receiver_info_id     :integer
#
# Indexes
#
#  index_shipments_on_active            (active)
#  index_shipments_on_receiver_info_id  (receiver_info_id)
#  index_shipments_on_shipper_info_id   (shipper_info_id)
#  index_shipments_on_user_id           (user_id)
#

class Shipment < ActiveRecord::Base
  belongs_to :user
  belongs_to :shipper_info
  belongs_to :receiver_info

  has_many :ship_invitations, dependent: :destroy
  has_many :shipment_feedbacks, dependent: :destroy

  mount_uploader :picture, ShipmentPictureUploader
  resourcify

  scope :active, ->() {where(active: true)}
  scope :public_only, ->() {where(private_bidding: false)}

  # Used for validation here, in swagger doc generation (for swagger_api methods and swagger_model)
  # -> :required or :optional for swagger
  # -> for_model: true > only use in swagger_model
  ATTRS = {dim_w: {desc: 'Width', required: :required, type: :double},
           dim_h: {desc: 'Height', required: :required, type: :double},
           dim_l: {desc: 'Length', required: :required, type: :double},
           distance: {desc: 'Distance', required: :required, type: :integer},
           notes: {desc: 'Notes', required: :optional, type: :string},
           price: {desc: 'Price', required: :required, type: :double},
           n_of_cartons: {desc: 'Number of cartons', required: :required, type: :integer},
           cubic_feet: {desc: 'Cubic feet', required: :required, type: :integer},
           unit_count: {desc: 'Unit count', required: :required, type: :integer},
           skids_count: {desc: 'Skids count', required: :required, type: :integer},
           hazard: {desc: 'Is hazard', required: :optional, type: :boolean, default: :false},
           private_bidding: {desc: 'Is private bidding by link', required: :optional, type: :boolean, default: :false},
           active: {desc: 'Is active', required: :optional, type: :boolean, default: :true},
           stackable: {desc: 'Is stackable', required: :optional, type: :boolean, default: :true},
           pickup_at: {desc: 'Pickup time', required: :required, type: :datetime},
           arrive_at: {desc: 'Arrive time', required: :required, type: :datetime},
           original_shipment_id: {desc: 'Repeated from shipment', type: :integer, for_model: true},
           secret_id: {desc: 'Part for private url', type: :string, for_model: true}
  }

  before_create :set_secret_id

  validates_associated :shipper_info, :receiver_info

  ATTRS.each_pair do |k,v|
    validates_presence_of k if v[:required] == :required
  end

  def eligible_for_render?(param_secret_id, current_user)
    (!private_bidding && active?) || (private_bidding? && secret_id == param_secret_id && active?) || user == current_user
  end

  # Manage ship_invitations here. delete all when [], replace if size>0, or ignore if nil.
  # TODO maybe add 'user_ids' => [1,2,3] in future
  # invitations: {'emails' => ['email@example.com', 'email2@example.com']}
  # Also reset secret_id so "old" invitees will not get access
  def invite!(invitations = nil)
    if invitations.nil?
      # Ignore
    else # edit
      ship_invitations.each {|s| s.destroy } # Delete anyway
      emails = invitations['emails'].to_a.compact
      if emails.size > 0
        # fill new
        transaction do
          set_secret_id
          save!
          InviteCarriers.perform_async(self.id, emails)
          # ShipInvitation.invite_by_emails!(self, invitations)
        end
      end
    end
  end

  def toggle_active!
    update_attribute :active, !active?
  end

  def set_secret_id
    self.secret_id = (Shipment.last.try(:id)||0).to_s + SecureRandom.urlsafe_base64(nil, false)
  end

  def picture_url
    picture.url
  end

  def active!
    update_attribute :active, true
  end

  def inactive!
    update_attribute :active, false
  end

end