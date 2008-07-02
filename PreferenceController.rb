require 'osx/cocoa'

class PreferenceController < OSX::NSWindowController
  include OSX
  ib_outlets :email, :password, :verbose, :user_defaults
  ib_outlets :appController

  def awakeFromNib
    account_updated
  end

  protected

  def windowWillClose(sender)
    @user_defaults.save self
    account_updated
  end
  ib_action :windowWillClose

  def account_updated
    params = {
      :email => @email.stringValue,
      :password => @password.stringValue,
      :verbose => @verbose.state
    }
    @appController.account_updated params
  end
end
