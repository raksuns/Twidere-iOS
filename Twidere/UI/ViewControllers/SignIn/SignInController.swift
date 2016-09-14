//
//  SignInController.swift
//  Twidere
//
//  Created by Mariotaku Lee on 16/7/8.
//  Copyright © 2016 Mariotaku Dev. All rights reserved.
//

import UIKit
import SwiftyUserDefaults
import CoreData
import PromiseKit
import SwiftyJSON
import ALSLayouts
import SwiftOverlays

class SignInController: UIViewController {
    
    var customAPIConfig: CustomAPIConfig = CustomAPIConfig()
    
    // MARK: Properties
    @IBOutlet weak var signUpButton: UIButton!
    @IBOutlet weak var loginButton: UIButton!
    @IBOutlet weak var passwordSignInButton: UIButton!
    @IBOutlet weak var editUsername: UITextField!
    @IBOutlet weak var editPassword: UITextField!
    @IBOutlet weak var signInContainer: ALSLinearLayout!
    @IBOutlet weak var signUpSignInContainer: ALSLinearLayout!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Setup button colors
        signUpButton.layer.borderColor = signUpButton.tintColor.cgColor
        loginButton.tintColor = materialLightGreen
        loginButton.layer.borderColor = materialLightGreen.cgColor
        
        customAPIConfig.loadDefaults()
        
        updateSignInUi()
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        switch segue.identifier {
        case "ShowAPIEditor"?:
            let dest = segue.destination as! APIEditorController
            dest.customAPIConfig = customAPIConfig
            dest.callback = { config in
                self.customAPIConfig = config
                self.updateSignInUi()
            }
        default: break
        }
    }
    
    @IBAction func unwindFromPasswordSignIn(_ segue: UIStoryboardSegue) {
        switch segue.identifier {
        case "DoPasswordSignIn"?:
            let vc = segue.source as! PasswordSignInController
            let (username, password) = vc.usernamePassword
            doOAuthPasswordSignIn(username, password: password)
        default: break
        }
    }
    
    @IBAction func signInClicked(_ sender: UIButton) {
        switch customAPIConfig.authType {
        case .OAuth:
            doBrowserSignIn()
        case .xAuth:
            doXAuthSignIn()
        case .TwipO:
            doTwipOSignIn()
        case .Basic:
            doBasicSignIn()
        }
        
    }
    
    @IBAction func cancelSignIn(_ sender: UIBarButtonItem) {
        dismiss(animated: true, completion: nil)
    }
    
    @IBAction func openSettingsMenu(_ sender: UIBarButtonItem) {
        let actionSheet: UIAlertController = UIAlertController(title: "Settings", message: nil, preferredStyle: .actionSheet)
        
        let cancelAction: UIAlertAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        actionSheet.addAction(cancelAction)
        
        let saveAction: UIAlertAction = UIAlertAction(title: "Edit API", style: .default) { action -> Void in
            self.performSegue(withIdentifier: "ShowAPIEditor", sender: self)
        }
        actionSheet.addAction(saveAction)
        
        let deleteAction: UIAlertAction = UIAlertAction(title: "Settings", style: .default) { action -> Void in
            self.performSegue(withIdentifier: "ShowPreferences", sender: self)
        }
        actionSheet.addAction(deleteAction)
        present(actionSheet, animated: true, completion: nil)
    }
    
    fileprivate func updateSignInUi() {
        if (customAPIConfig.authType == .OAuth) {
            passwordSignInButton.layoutParams.hidden = false
        } else {
            passwordSignInButton.layoutParams.hidden = true
        }
        if (customAPIConfig.authType.usePassword) {
            editUsername.layoutParams.hidden = false
            editPassword.layoutParams.hidden = false
            
            signUpSignInContainer.orientation = .Horizontal
        } else {
            editUsername.layoutParams.hidden = true
            editPassword.layoutParams.hidden = true
            
            signUpSignInContainer.orientation = .Vertical
        }
        signInContainer.setNeedsLayout()
    }
    
    fileprivate func doBrowserSignIn() {
        let apiConfig = self.customAPIConfig
        let endpoint = apiConfig.createEndpoint("api", noVersionSuffix: true, fixUrl: SignInController.fixSignInUrl)
        let auth = OAuthAuthorization(apiConfig.consumerKey!, apiConfig.consumerSecret!)
        let oauth = OAuthService(endpoint: endpoint, auth: auth)
        
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        SwiftOverlays.showBlockingWaitOverlay()
        
        oauth.getRequestToken("oob").then { token -> Void in
            let vc = self.storyboard?.instantiateViewControllerWithIdentifier("BrowserSignIn") as! BrowserSignInController
            vc.customAPIConfig = self.customAPIConfig
            vc.requestToken = token
            vc.callback = self.finishBrowserSignIn
            self.showViewController(vc, sender: self)
            }.always {
                UIApplication.sharedApplication().networkActivityIndicatorVisible = false
                SwiftOverlays.removeAllBlockingOverlays()
            }.error { error in
                debugPrint(error)
        }
    }
    
    fileprivate func doOAuthPasswordSignIn(_ username: String, password: String) {
        let userAgent = UIWebView().stringByEvaluatingJavaScript(from: "navigator.userAgent")
        
        doSignIn { config -> Promise<SignInResult> in
            let apiConfig = self.customAPIConfig
            var endpoint = apiConfig.createEndpoint("api", noVersionSuffix: true)
            let authenticator = TwitterOAuthPasswordAuthenticator(endpoint: endpoint, consumerKey: apiConfig.consumerKey!, consumerSecret: apiConfig.consumerSecret!, loginVerificationCallback: { challengeType -> String? in
                let sem = dispatch_semaphore_create(0)
                let vc = UIAlertController(title: "Login verification", message: "[Verification message here]", preferredStyle: .Alert)
                var challangeResponse: String? = nil
                vc.addTextFieldWithConfigurationHandler{ textField in
                    textField.keyboardType = .EmailAddress
                }
                vc.addAction(UIAlertAction(title: "OK", style: .Default, handler: { action in
                    challangeResponse = vc.textFields?[0].text
                    dispatch_semaphore_signal(sem)
                }))
                vc.addAction(UIAlertAction(title: "Cancel", style: .Cancel, handler: nil))
                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER)
                return challangeResponse
                }, browserUserAgent: userAgent)
            return authenticator.getOAuthAccessToken(username, password: password)
                .then { accessToken -> Promise<SignInResult> in
                    return Promise { fullfull, reject in
                        
                        let auth = OAuthAuthorization(apiConfig.consumerKey!, apiConfig.consumerSecret!, oauthToken: accessToken)
                        endpoint = apiConfig.createEndpoint("api")
                        
                        let microBlog = MicroBlogService(endpoint: endpoint, auth: auth)
                        microBlog.verifyCredentials().then { user -> Void in
                            fullfull(SignInResult(user: user, accessToken: accessToken))
                            }.error { error -> Void in
                                reject(error)
                        }
                    }
            }
        }
    }
    
    fileprivate func doXAuthSignIn() {
        let username = editUsername.text ?? ""
        let password = editPassword.text ?? ""
        doSignIn { config -> Promise<SignInResult> in
            let apiConfig = self.customAPIConfig
            var endpoint = apiConfig.createEndpoint("api", noVersionSuffix: true, fixUrl: SignInController.fixSignInUrl)
            let oauth = OAuthService(endpoint: endpoint, auth: OAuthAuthorization(apiConfig.consumerKey!, apiConfig.consumerSecret!))
            return oauth.getAccessToken(username, xauthPassword: password)
                .then { accessToken -> Promise<SignInResult> in
                    return Promise { fullfull, reject in
                        
                        let auth = OAuthAuthorization(apiConfig.consumerKey!, apiConfig.consumerSecret!, oauthToken: accessToken)
                        endpoint = apiConfig.createEndpoint("api")
                        
                        let microBlog = MicroBlogService(endpoint: endpoint, auth: auth)
                        microBlog.verifyCredentials().then { user -> Void in
                            fullfull(SignInResult(user: user, accessToken: accessToken))
                            }.error { error -> Void in
                                reject(error)
                        }
                    }
            }
        }
    }
    
    fileprivate func doBasicSignIn() {
        let username = editUsername.text ?? ""
        let password = editPassword.text ?? ""
        doSignIn { config -> Promise<SignInResult> in
            let endpoint = self.customAPIConfig.createEndpoint("api")
            let auth = BasicAuthorization(username: username, password: password)
            let microBlog = MicroBlogService(endpoint: endpoint, auth: auth)
            return microBlog.verifyCredentials().then { user -> SignInResult in
                return SignInResult(user: user, username: username, password: password)
            }
        }
    }
    
    fileprivate func doTwipOSignIn() {
        doSignIn { config -> Promise<SignInResult> in
            let endpoint = self.customAPIConfig.createEndpoint("api")
            let microBlog = MicroBlogService(endpoint: endpoint)
            return microBlog.verifyCredentials().then { user -> SignInResult in
                return SignInResult(user: user)
            }
        }
    }
    
    fileprivate func finishBrowserSignIn(_ requestToken: OAuthToken, oauthVerifier: String?) {
        doSignIn { config -> Promise<SignInResult> in
            let apiConfig = self.customAPIConfig
            var endpoint = apiConfig.createEndpoint("api", noVersionSuffix: true, fixUrl: SignInController.fixSignInUrl)
            let oauth = OAuthService(endpoint: endpoint, auth: OAuthAuthorization(apiConfig.consumerKey!, apiConfig.consumerSecret!))
            return oauth.getAccessToken(requestToken, oauthVerifier: oauthVerifier)
                .then { accessToken -> Promise<SignInResult> in
                    return Promise { fullfull, reject in
                        
                        let auth = OAuthAuthorization(apiConfig.consumerKey!, apiConfig.consumerSecret!, oauthToken: accessToken)
                        endpoint = apiConfig.createEndpoint("api")
                        
                        let microBlog = MicroBlogService(endpoint: endpoint, auth: auth)
                        microBlog.verifyCredentials().then { user -> Void in
                            fullfull(SignInResult(user: user, accessToken: accessToken))
                            }.error { error -> Void in
                                reject(error)
                        }
                    }
            }
        }
    }
    
    fileprivate func doSignIn(_ action: (_ config: CustomAPIConfig) -> Promise<SignInResult>) {
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        SwiftOverlays.showBlockingWaitOverlay()
        action(config: self.customAPIConfig).then { result throws -> Account in
            let json = result.user
            let config = self.customAPIConfig
            let db = (UIApplication.sharedApplication().delegate as! AppDelegate).sqliteDatabase
            let account = Account()
            let user = User(accountJson: json)
            account.key = user.key
            account.type = String(AccountType.Twitter)
            account.apiUrlFormat = config.apiUrlFormat
            account.authType = String(config.authType)
            account.basicUsername = result.username
            account.basicPassword = result.password
            account.consumerKey = config.consumerKey
            account.consumerSecret = config.consumerSecret
            account.noVersionSuffix = config.noVersionSuffix
            account.oauthToken = result.accessToken?.oauthToken
            account.oauthTokenSecret = result.accessToken?.oauthTokenSecret
            account.sameOAuthSigningUrl = config.sameOAuthSigningUrl
            account.user = user
            try db.transaction {
                try db.run(Account.insertData(accountsTable, model: account))
            }
            return account
            }.then { result -> Void in
                let home = self.storyboard!.instantiateViewControllerWithIdentifier("Main")
                self.presentViewController(home, animated: true, completion: nil)
            }.always {
                SwiftOverlays.removeAllBlockingOverlays()
                UIApplication.sharedApplication().networkActivityIndicatorVisible = false
            }.error { error in
                if (error is AuthenticationError) {
                    switch (error) {
                    case AuthenticationError.AccessTokenFailed:
                        let vc = UIAlertController(title: nil, message: "Unable to get access token", preferredStyle: .Alert)
                        self.presentViewController(vc, animated: true, completion: nil)
                    case AuthenticationError.RequestTokenFailed:
                        let vc = UIAlertController(title: nil, message: "Unable to get request token", preferredStyle: .Alert)
                        self.presentViewController(vc, animated: true, completion: nil)
                    case AuthenticationError.WrongUsernamePassword:
                        let vc = UIAlertController(title: nil, message: "Wrong username or password", preferredStyle: .Alert)
                        self.presentViewController(vc, animated: true, completion: nil)
                    case AuthenticationError.VerificationFailed:
                        let vc = UIAlertController(title: nil, message: "Verification failed", preferredStyle: .Alert)
                        self.presentViewController(vc, animated: true, completion: nil)
                    default: break
                    }
                }
                debugPrint(error)
        }
    }
    
    static func fixSignInUrl(_ url: String) -> String {
        guard let urlComponents = URLComponents(string: url) else {
            return url
        }
        if ("api.fanfou.com" == urlComponents.host) {
            if (urlComponents.path.hasPrefix("/oauth/") ?? false) {
                urlComponents.host = "fanfou.com"
            }
        }
        return urlComponents.string ?? url
    }
}


class SignInResult {
    var user: JSON
    var accessToken: OAuthToken? = nil
    var username: String? = nil
    var password: String? = nil
    
    init(user: JSON) {
        self.user = user
    }
    
    init(user: JSON, accessToken: OAuthToken) {
        self.user = user
        self.accessToken = accessToken
    }
    
    init(user: JSON, username: String, password: String) {
        self.user = user
        self.username = username
        self.password = password
    }
}
