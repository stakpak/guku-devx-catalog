package k8s

import (
	"stakpak.dev/devx/v1"
	"stakpak.dev/devx/v1/traits"
	schema "stakpak.dev/devx/v1/transformers/terraform"
	resources "stakpak.dev/devx/k8s/services/eso/resources"
)

#AddExternalSecret: v1.#Transformer & {
	traits.#Secret
	$metadata: _
	secrets:   _

	k8s: {
		namespace: string
		...
	}

	externalSecret: {
		refreshInterval: *"1h" | string
		storeRef: {
			name: string
			kind: *"ClusterSecretStore" | "SecretStore"
		}
		decodingStrategy: *"None" | "Base64" | "Base64URL" | "Auto"
	}

	let secretObjs = {
		for _, secret in secrets {
			"\(secret.name)": {
				data: secret
				properties: {
					if secret.property != _|_ {
						"\(secret.property)": null
					}
				}
				template: secret.template
			}
		}
	}

	$resources: terraform: schema.#Terraform & {
		resource: kubernetes_manifest: {
			for secretName, obj in secretObjs {
				"\(secretName)_external_secret": {
					manifest: resources.#ExternalSecret & {
						metadata: {
							name:      secretName
							namespace: k8s.namespace
						}
						spec: {
							refreshInterval: externalSecret.refreshInterval
							secretStoreRef: {
								name: externalSecret.storeRef.name
								kind: externalSecret.storeRef.kind
							}

							if obj.template == _|_ {
								if len(obj.properties) == 0 {
									data: [{
										secretKey: "value"
										remoteRef: {
											key:              secretName
											version:          obj.data.version | *"latest"
											decodingStrategy: externalSecret.decodingStrategy
										}
									}]
								}
								if len(obj.properties) > 0 {
									data: [
										for propertyName, _ in obj.properties {
											secretKey: propertyName
											remoteRef: {
												key:              secretName
												version:          obj.data.version | *"latest"
												property:         propertyName
												decodingStrategy: externalSecret.decodingStrategy
											}
										},
									]
								}
							}
							if obj.template != _|_ {
								target: template: {
									engineVersion: "v2"
									data: [{
										value: obj.template.value
									}]
								}
								data: [
									for propertyName, propertyObj in obj.template.properties {
										secretKey: propertyName
										remoteRef: {
											key:     propertyObj.name
											version: obj.data.version | *"latest"
											if propertyObj.property != _|_ {
												property: propertyObj.property
											}
											decodingStrategy: externalSecret.decodingStrategy
										}
									},
								]
							}
						}
					}
					if $metadata.labels.force_conflicts != _|_ {
						field_manager: force_conflicts: true
					}
				}
			}
		}
	}
}

#AddImagePullSecret: v1.#Transformer & {
	traits.#ImagePullSecret
	$metadata: _
	secret:    _

	k8s: {
		namespace: string
		...
	}
	externalSecret: {
		refreshInterval: *"1h" | string
	}

	$resources: terraform: schema.#Terraform & {
		if secret.provider == "aws" {
			resource: kubernetes_manifest: {
				"\($metadata.id)_authorization_token": {
					manifest: resources.#ECRAuthorizationToken & {
						metadata: {
							name:      "\($metadata.id)-authorization-token"
							namespace: k8s.namespace
						}
						spec: {
							region: secret.region
							auth: secretRef: {
								accessKeyIDSecretRef: {
									name: secret.accessKey.name
									key:  secret.accessKey.key
								}
								secretAccessKeySecretRef: {
									name: secret.secretAccessKey.name
									key:  secret.secretAccessKey.key
								}
							}
						}
					}
				}

				"\($metadata.id)_image_pull_secret": {
					manifest: resources.#ExternalSecret & {
						metadata: {
							name:      "\($metadata.id)-image-pull-secret"
							namespace: k8s.namespace
						}
						spec: {
							refreshInterval: externalSecret.refreshInterval
							target: {
								template: {
									type: "kubernetes.io/dockerconfigjson"
									data: ".dockerconfigjson": #"{"auths":{"{{ .proxy_endpoint }}":{"username":"{{ .username }}","password":"{{ .password }}","auth":"{{ printf "%s:%s" .username .password | b64enc }}"}}}"#
								}
								name:           "\($metadata.id)-image-pull-secret"
								creationPolicy: "Owner"
							}
							dataFrom: [
								{
									sourceRef: generatorRef: {
										apiVersion: "generators.external-secrets.io/v1alpha1"
										name:       "\($metadata.id)-authorization-token"
										kind:       "ECRAuthorizationToken"
									}
								},
							]
						}
					}
				}

			}
		}
	}

}

#AddIAMUserSecret: v1.#Transformer & {
	traits.#User
	$metadata:           _
	overrideSecretName?: string
	users: [string]: {
		username: string
		if overrideSecretName == _|_ {
			password: name: "\(username)"
		}
		if overrideSecretName != _|_ {
			password: name: "\(overrideSecretName)"
		}
	}
	k8s: {
		namespace: string
		...
	}
	$resources: terraform: schema.#Terraform & {
		resource: kubernetes_secret_v1: {
			for _, user in users {
				"\($metadata.id)_\(user.username)": {
					metadata: {
						namespace: k8s.namespace
						if overrideSecretName == _|_ {
							name: user.username
						}
						if overrideSecretName != _|_ {
							name: "\(overrideSecretName)"
						}
					}
					data: {
						accessKeyID: "${aws_iam_access_key.\(user.username).id}"
						secretKey:   "${aws_iam_access_key.\(user.username).secret}"
					}
				}
			}
		}
	}
}
