cask "pinga" do
  version "0.1.0"
  sha256 "322ed23263e9aad8ecd77129d376d23e6d11bf80575dc65e875ad2ae94f018ae"
  url "https://github.com/sarangkharche/Pinga/releases/download/v#{version}/Pinga.zip"
  name "Pinga"
  desc "Native macOS notifications for GitHub pull requests"
  homepage "https://github.com/sarangkharche/Pinga"
  depends_on arch: :arm64
  depends_on macos: ">= :ventura"
  depends_on formula: "gh"
  app "Pinga.app"
end
