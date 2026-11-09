cask "pinga" do
  version "0.1.0"
  sha256 "322ed23263e9aad8ecd77129d376d23e6d11bf80575dc65e875ad2ae94f018ae"

  url "https://github.com/sarangkharche/Pinga/releases/download/v#{version}/Pinga.zip"
  name "Pinga"
  desc "Notifications for GitHub pull requests"
  homepage "https://github.com/sarangkharche/Pinga"

  depends_on arch: :arm64
  depends_on formula: "gh"
  depends_on macos: :ventura

  app "Pinga.app"
end
